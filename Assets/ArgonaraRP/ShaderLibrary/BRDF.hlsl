#ifndef CUSTOM_BRDF_INCLUDED
#define CUSTOM_BRDF_INCLUDED

#define kDielectricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04)

//BRDF结构体，只存计算所需的中间值，避免重复计算，then获取直接光和间接光，在DirectBRDF和IndirectBRDF两个函数
struct BRDF
{
    //float directKd;//直接光漫反射系数     oneMinusReflectivity，现在在MetaPass的漫反射计算中，这个简化的Kd，现在不用于实时计算，所以这里没有
    float3 albedo;//是否预乘alpha，会造成albedo是否受surface.alpha影响
    float3 F0;
    
    float perceptualRoughness;
    float roughness;
    float roughnessSquare;
};

//--------------直接光漫反射----------------

//获取直接光Kd
float3 GetDirectKd(float3 F, float metallic)//F是镜面BRDF高光的fresnel项
{
    return (1 - F) * (1.0 - metallic);
}
//不需要去算Ks，因为高光项里面就有一个F，那就是Ks，再额外乘会出错

float3 GetDirectDiffuse(float3 Kd, float3 albedo)
{
    return Kd * albedo;
}

//--------------直接光高光----------------
float DistributionGGX(float nh, float squareRoughness) {
    return squareRoughness / pow(pow(nh, 2) * (squareRoughness - 1) + 1, 2)/UNITY_PI;
}
			
float GeometrySmith(float nl, float nv, float kInDirectLight) {
    float GLeft = nl / lerp(nl, 1, kInDirectLight);
    float GRight = nv / lerp(nv, 1, kInDirectLight);
    float G = GLeft * GRight;
    return G;
}
			
//直接光用到的F项，和光线方向有关      direct use hv，微观
float3 fresnelSchlick(float vh, float3 F0) {
    return F0 + (1 - F0) * exp2((-5.55473 * vh - 6.98316) * vh);
}
			
//间接光用到的粗糙度版本菲涅尔        indirect use nv, 宏观
float3 fresnelSchlickRoughness(float nv, float3 F0,float roughness)
{
    float3 F = exp2((-5.55473 * nv - 6.98316 ) * nv);
    return F0 + F * saturate(1 - roughness - F0);
}

float3 GetDirectSpecular(float D, float G, float3 F, float nv, float nl)
{
    return D * G * F * (0.25) / (nv * nl);
}

//直接光BRDF = 直接光diffuse + 直接光specular (无光照)
float3 DirectBRDF(Surface surface, BRDF brdf, Light light)
{
    float3 halfVector = normalize(light.direction + surface.viewDirection);
    float nl = max(saturate(dot(surface.normal, light.direction)), 0.000001);//防止除0
    float nv = max(saturate(dot(surface.normal, surface.viewDirection)), 0.000001);
    float vh = max(saturate(dot(surface.viewDirection, halfVector)), 0.000001);
    float nh = max(saturate(dot(surface.normal, halfVector)), 0.000001);
    
    //先算DGF
    float D = DistributionGGX(nh, brdf.roughnessSquare);
    float kInDirectLight = pow(brdf.roughnessSquare + 1, 2) / 8;
    float G = GeometrySmith(nl, nv, kInDirectLight);
    float3 F0 = brdf.F0;
    float3 F = fresnelSchlick(vh, F0);
    
    float3 directSpecular = GetDirectSpecular(D, G, F, nv, nl);
    
    float3 Kd = GetDirectKd(F, surface.metallic);
    float3 directDiffuse = GetDirectDiffuse(Kd, brdf.albedo);
    
    return directDiffuse + directSpecular;
}

//---------------间接光漫反射+高光-----------------

float OneMinusReflectivityMetallic(float metallic)
{
    half oneMinusDielectricSpec = kDielectricSpec.a;
    return oneMinusDielectricSpec - metallic * oneMinusDielectricSpec;
}

//间接高光，曲线拟合，近似LUT的效果
float3 IndirSpecFactor(float roughnessSquare,float roughness,float metallic,float3 F0,float NdotV)
{
    float surfaceReduction = 1/(roughnessSquare+1);//表面亮度降低。当粗糙度更大，高光被摊得更开，单点亮度更小，then整体亮度factor变低
				
    half oneMinusReflectivity = OneMinusReflectivityMetallic(metallic);//返回0.96*(1-metallic)
    half reflectivity = half(1.0) - oneMinusReflectivity;//返回0.04+0.96*metaiilc，就是金属度为0，就是非金属F0为0.04，全金属就是金属的F0为1
				
    //grazing，轻擦、擦破、擦过
    half grazingTerm = saturate((1.0 - roughness) + reflectivity);
    float fresnelTerm = Pow4(1.0-NdotV);//视线边缘，菲涅尔效果最强
				
    return surfaceReduction * lerp(F0,grazingTerm,fresnelTerm);//直射时候系数就是F0正视角反射率，掠射的时候系数是算出的grazingTerm“掠射角反射率”的经验近似
}

//间接光BRDF = 间接光diffuse + 间接光specular
float3 IndirectBRDF(Surface surface, BRDF brdf, float3 giDiffuse, float3 giSpecular)
{
    float nv = max(saturate(dot(surface.normal, surface.viewDirection)), 0.000001);
    float3 F = fresnelSchlickRoughness(nv, brdf.F0, brdf.roughness);
    float3 k_d = (1.0 - F) * (1.0 - surface.metallic);
    //间接漫反射
    float3 indirectDiffuse = giDiffuse * k_d * brdf.albedo;
    //间接高光
    float3 indirectSpecFactor = IndirSpecFactor(brdf.roughnessSquare, surface.roughness, surface.metallic, brdf.F0, nv);
    float3 indirectSpecular = giSpecular * indirectSpecFactor;
    
    return (indirectDiffuse + indirectSpecular) * surface.occlusion;
}



BRDF GetBRDF(Surface surface, bool applyAlphaToDiffuse = false)//我们可能会在此修改surface，故改为inout
{
    BRDF brdf;
    
    //基础基础信息
    brdf.perceptualRoughness = surface.roughness;//1-perceptual smoothness
    brdf.roughness = PerceptualRoughnessToRoughness(brdf.perceptualRoughness);//对perceptual roughness平方
    brdf.roughnessSquare = pow(lerp(0.002, 1, brdf.roughness), 2);
    
    brdf.F0 = lerp(kDielectricSpec.rgb, surface.albedo, surface.metallic);
    
    //oneMinusReflectivity，，，是原本的简化版Kd，等于0.96 * (1 - metallic)，现已被替代，故BRDF结构体没存它，但MetaPass的漫反射光照计算在用这个
    
    brdf.albedo = surface.albedo;
    if (applyAlphaToDiffuse) {//若启用，材质会像玻璃，高光反射不受alpha影响，默认false
        //漫反射会根据alpha褪色，但是对于完全透明玻璃，光线要么穿过，要么被反射，因此镜面反射不会褪色
        //因此我们不能用SrcAlpha,OneMinusSrcAlpha，改为One,OneMinusSrcAlpha，这样duffuse和specular都不因GPU透明混合而褪色了
        //所以，对diffuse预乘alpha混合
        brdf.albedo *= surface.alpha;
    }
    
    return brdf;
}

#endif