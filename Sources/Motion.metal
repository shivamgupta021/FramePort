#include <metal_stdlib>
using namespace metal;

constexpr sampler linearPixel(coord::pixel, address::clamp_to_edge, filter::linear);
constexpr sampler nearestPixel(coord::pixel, address::clamp_to_edge, filter::nearest);

// Catmull–Rom reconstruction for the smaller temporal guide. Clamp each
// result to the four enclosing samples so thin high-contrast lines cannot ring.
float4 cubicWeights(float t) {
    float t2=t*t, t3=t2*t;
    return float4(-0.5*t+t2-0.5*t3, 1.0-2.5*t2+1.5*t3,
                   0.5*t+2.0*t2-1.5*t3, -0.5*t2+0.5*t3);
}
float4 sampleGuide(texture2d<float> guide, float2 p) {
    float2 base=floor(p-0.5)+0.5, t=p-base;
    float4 wx=cubicWeights(t.x), wy=cubicWeights(t.y);
    float4 sum=0, lo=1, hi=0;
    for (int y=0;y<4;y++) for (int x=0;x<4;x++) {
        float4 v=guide.sample(nearestPixel,base+float2(x-1,y-1));
        sum+=v*wx[x]*wy[y];
        if (x==1 || x==2) if (y==1 || y==2) { lo=min(lo,v); hi=max(hi,v); }
    }
    return clamp(sum,lo,hi);
}

// Use the temporal prediction wherever a contour moves. Recover native detail
// only when both real references agree across the surrounding patch.
kernel void reconstructGuide(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                             texture2d<float> guide [[texture(2)]], texture2d<float,access::write> dest [[texture(3)]],
                             texture2d<float> motion [[texture(4)]], constant bool &luma [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 p = float2(gid)+0.5;
    float2 uv = p*float2(guide.get_width(),guide.get_height())/float2(dest.get_width(),dest.get_height());
    float4 predicted = sampleGuide(guide,uv);
    float4 real = (a.sample(nearestPixel,p)+b.sample(nearestPixel,p))*0.5;
    float disagreement = 0;
    for (int y=-2;y<=2;y+=2) for (int x=-2;x<=2;x+=2) {
        float2 delta = abs(a.sample(nearestPixel,p+float2(x,y)).rg-b.sample(nearestPixel,p+float2(x,y)).rg);
        disagreement = max(disagreement,max(delta.r,delta.g));
    }
    float stable = 1-smoothstep(0.012,0.06,disagreement);
    if (luma && stable < 1) {
        // Reintroduce only the band of native detail missing from the guide.
        // Compare both motion-aligned source patches and the prediction before
        // borrowing texture. An uncertain silhouette stays with the guide.
        float2 v=motion.sample(linearPixel,(p-0.5)/12.0).xy;
        float2 ratio=float2(guide.get_width(),guide.get_height())/float2(dest.get_width(),dest.get_height());
        float original=0.5*(a.sample(linearPixel,p-v).r+b.sample(linearPixel,p+v).r);
        float originalLow=0, guideLow=0, pairError=0, guideError=0;
        const float2 offsets[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
        for (int k=0;k<4;k++) {
            float2 d=offsets[k]*1.4;
            float ca=a.sample(linearPixel,p-v+d).r, cb=b.sample(linearPixel,p+v+d).r;
            float cg=guide.sample(linearPixel,uv+d*ratio).r;
            originalLow+=(ca+cb)*0.125;
            guideLow+=cg*0.25;
            pairError+=abs(ca-cb)*0.25;
            guideError+=abs((ca+cb)*0.5-cg)*0.25;
        }
        float trust=(1-smoothstep(0.018,0.085,pairError))*(1-smoothstep(0.025,0.10,guideError));
        float residual=(original-originalLow)-(predicted.r-guideLow);
        predicted.r+=0.85*trust*clamp(residual,-0.10,0.10);
    }
    dest.write(mix(predicted,real,stable),gid);
}

// Search for a displacement centered on the intermediate image. Test a sparse
// textured neighborhood in the two real images on either side of that position.
float cost(texture2d<float> a, texture2d<float> b, float2 center, float2 offset) {
    float total = 0;
    for (int y = -6; y <= 6; y += 4)
        for (int x = -6; x <= 6; x += 4) {
            float2 p = center + float2(x,y);
            total += abs(a.sample(nearestPixel,p-offset).r - b.sample(nearestPixel,p+offset).r);
        }
    return total;
}
kernel void downsample(texture2d<float> source [[texture(0)]], texture2d<float,access::write> target [[texture(1)]],
                       uint2 cell [[thread_position_in_grid]]) {
    if (cell.x >= target.get_width() || cell.y >= target.get_height()) return;
    float2 p = float2(cell)*4.0+1.0;
    float sum = source.sample(linearPixel,p).r + source.sample(linearPixel,p+float2(2,0)).r
        + source.sample(linearPixel,p+float2(0,2)).r + source.sample(linearPixel,p+2.0).r;
    target.write(float4(sum*0.25),cell);
}
void tryOffset(texture2d<float> a, texture2d<float> b, float2 center, float2 offset,
               thread float &minimum, thread float2 &best) {
    float score = cost(a,b,center,offset) + 0.00015*length(offset);
    if (score < minimum) { minimum=score; best=offset; }
}
void refine(texture2d<float> a, texture2d<float> b, float2 center, int step,
            thread float &minimum, thread float2 &best) {
    float2 origin=best;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++)
        tryOffset(a,b,center,origin+float2(x,y)*step,minimum,best);
}
// Search broad pans on low-pass luma, then refine each 12-pixel neighborhood
// against the full-resolution originals. Displacements are half-frame offsets.
kernel void coarseMotion(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                         texture2d<float,access::write> field [[texture(2)]], uint2 grid [[thread_position_in_grid]]) {
    if (grid.x >= field.get_width() || grid.y >= field.get_height()) return;
    float2 center=float2(grid)*12.0+6.5, best=0;
    float minimum=cost(a,b,center,0);
    if(minimum>0.015) {
        for(int y=-16;y<=16;y+=2) for(int x=-16;x<=16;x+=2)
            tryOffset(a,b,center,float2(x,y),minimum,best);
        refine(a,b,center,1,minimum,best);
    }
    field.write(float4(best*4,0,1),grid);
}
kernel void estimate(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                     texture2d<float,access::write> field [[texture(2)]], texture2d<float> coarse [[texture(3)]],
                     uint2 grid [[thread_position_in_grid]]) {
    if (grid.x >= field.get_width() || grid.y >= field.get_height()) return;
    float2 center = float2(grid)*12.0+6.5, best=0;
    float minimum=cost(a,b,center,0);
    if (minimum>0.015) {
        // Keep an independent small-motion search. A coarse match on a
        // repeated background must not displace a slow-moving foreground edge.
        for (int y=-6;y<=6;y+=2) for (int x=-6;x<=6;x+=2)
            tryOffset(a,b,center,float2(x,y),minimum,best);
        float2 seedCell=floor(center/48.0-0.5)+0.5;
        for(int y=0;y<=1;y++) for(int x=0;x<=1;x++)
            tryOffset(a,b,center,coarse.sample(nearestPixel,seedCell+float2(x,y)).xy,minimum,best);
        refine(a,b,center,4,minimum,best);
        refine(a,b,center,2,minimum,best);
        refine(a,b,center,1,minimum,best);
    }
    field.write(float4(best,0,1),grid);
}

// Use luma support for both output planes. Choosing a different vector by
// chroma alone can split a colored outline away from its luminance edge.
float matchError(texture2d<float> a, texture2d<float> b, float2 p, float2 v) {
    float2 left=p-v, right=p+v;
    float e=2*abs(a.sample(linearPixel,left).r-b.sample(linearPixel,right).r);
    const float2 offsets[4]={float2(-2,0),float2(2,0),float2(0,-2),float2(0,2)};
    for(int i=0;i<4;i++) e+=abs(a.sample(linearPixel,left+offsets[i]).r-b.sample(linearPixel,right+offsets[i]).r);
    return e/6;
}
kernel void midpoint(texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                     texture2d<float> field [[texture(2)]], texture2d<float,access::write> dest [[texture(3)]],
                     texture2d<float> lumaA [[texture(4)]], texture2d<float> lumaB [[texture(5)]],
                     constant float &planeScale [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 p=(float2(gid)+0.5)*float2(a.get_width(),a.get_height())/float2(dest.get_width(),dest.get_height());
    float2 position=p*planeScale;
    float2 grid=(position-0.5)/12.0, cell=floor(grid-0.5)+0.5;
    float2 v=field.sample(linearPixel,grid).xy;
    float best=matchError(lumaA,lumaB,position,v);
    if(best>0.008) {
        // At motion boundaries a bilinear average can point between two objects.
        // Compare the neighboring motions on a local patch, including zero for HUDs.
        float fixedError=matchError(lumaA,lumaB,position,0);
        if(fixedError<best) { v=0; best=fixedError; }
        for(int y=0;y<=1;y++) for(int x=0;x<=1;x++) {
            float2 neighbor=field.sample(nearestPixel,cell+float2(x,y)).xy;
            float e=matchError(lumaA,lumaB,position,neighbor);
            if(e<best) {v=neighbor; best=e;}
        }
    }
    float mismatch=abs(lumaA.sample(linearPixel,position-v).r-lumaB.sample(linearPixel,position+v).r);
    float4 result;
    if(best>0.065 || mismatch>0.11) {
        // Unmatched content, including newly revealed surfaces. Keep one real
        // sample here; mixing incompatible contours produces a second outline.
        // Find nearby agreement on each side of the disputed silhouette.
        // Carry color from the reference supported by neighboring visible
        // texture. A real sample from the nearest endpoint is the fallback
        // when neither trajectory has surviving support.
        float bestSupport=0.11;
        result=b.sample(linearPixel,p);
        const float2 directions[4]={float2(-1,0),float2(1,0),float2(0,-1),float2(0,1)};
        for(int candidate=0;candidate<5;candidate++) {
            float2 vel=candidate==4?v:field.sample(nearestPixel,cell+float2(candidate%2,candidate/2)).xy;
            float2 pa=position-vel, pb=position+vel;
            float ca=lumaA.sample(linearPixel,pa).r, cb=lumaB.sample(linearPixel,pb).r;
            for(int k=0;k<4;k++) {
                float2 off=directions[k]*5.0;
                float la=lumaA.sample(linearPixel,pa+off).r, lb=lumaB.sample(linearPixel,pb+off).r;
                float agreement=abs(la-lb);
                float left=agreement+abs(la-ca),right=agreement+abs(lb-cb);
                float support=min(left,right);
                if(support<bestSupport) {
                    bestSupport=support;
                    result=left<right?a.sample(linearPixel,p-vel/planeScale):b.sample(linearPixel,p+vel/planeScale);
                }
            }
        }
    } else {
        float4 left=a.sample(linearPixel,p-v/planeScale), right=b.sample(linearPixel,p+v/planeScale);
        result=mix((left+right)*0.5,right,smoothstep(0.025,0.08,mismatch));
    }
    dest.write(result,gid);
}
