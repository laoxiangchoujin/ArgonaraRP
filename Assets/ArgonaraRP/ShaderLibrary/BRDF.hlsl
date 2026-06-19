#ifndef CUSTOM_BRDF_INCLUDED
#define CUSTOM_BRDF_INCLUDED

#define MIN_REFLECTIVITY 0.04//完全非金属的反射率为0.04， 这就是F0

struct BRDF
{
    float3 diffuse;
    float3 specular;
    float roughness;
    float perceptualRoughness;//用这个粗糙度，获取镜面反射的mip级别，高mip级别模拟模糊的反射
    float fresnel;
};

float OneMinusReflectivity(float metallic)//返回的是1-Ks，也就是Kd
{
    float range = 1.0 - MIN_REFLECTIVITY;
    return range * (1.0 - metallic);
}

//完整的Cook-Torrance 高光公式是：f_specular = D · F · G / (4 · (N·L) · (N·V))
float SpecularStrength(Surface surface, BRDF brdf, Light light)//这不是一个完整的cook-toorance，只是一个够用就行的简单版本
{
    float3 h = SafeNormalize(light.direction + surface.viewDirection);
    float nh2 = Square(saturate(dot(surface.normal, h)));//NOH的平方
    float lh2 = Square(saturate(dot(light.direction, h)));//LOH的平方
    float r2 = Square(brdf.roughness);//粗糙度的平方
    float d2 = Square(nh2 * (r2 - 1.0) + 1.00001);//ggx ndf的分母的一部分
    float normalization = brdf.roughness * 4.0 + 2.0;//对光强的一个归一化拟合
    return r2 / (d2 * max(0.1, lh2) * normalization);
}

//计算高光结果
float3 DirectBRDF(Surface surface, BRDF brdf, Light light)
{
    return SpecularStrength(surface, brdf, light) * brdf.specular + brdf.diffuse;
}

float3 IndirectBRDF(Surface surface, BRDF brdf, float3 diffuse, float3 specular)//好像说，这里的diffuse和specular是全局光照的结果？
{
    float fresnelStrength = surface.fresnelStrength * Pow4(1.0 - saturate(dot(surface.normal, surface.viewDirection)));
    float3 reflection = specular * lerp(brdf.specular, brdf.fresnel, fresnelStrength);
    reflection /= brdf.roughness * brdf.roughness + 1.0;//粗糙度会让反射发生散射，这里，最大粗糙度让反射减半
    return (diffuse * brdf.diffuse + reflection) * surface.occlusion;
}

BRDF GetBRDF(inout Surface surface, bool applyAlphaToDiffuse = false)//我们可能会在此修改surface，故改为inout
{
    BRDF brdf;
    float oneMinusReflectivity = OneMinusReflectivity(surface.metallic);
    brdf.diffuse = surface.color * oneMinusReflectivity;//若金属度为1，duffuse为0， 若金属度为0，diffuse为color*0.96
    if (applyAlphaToDiffuse) {//若启用，材质会像玻璃，高光反射不受alpha影响，默认false
        //漫反射会根据alpha褪色，但是对于完全透明玻璃，光线要么穿过，要么被反射，因此镜面反射不会褪色
        //因此我们不能用SrcAlpha,OneMinusSrcAlpha，改为One,OneMinusSrcAlpha，这样duffuse和specular都不因GPU透明混合而褪色了
        //所以，对diffuse预乘alpha混合
        brdf.diffuse *= surface.alpha;
    }
    brdf.specular = lerp(MIN_REFLECTIVITY, surface.color, surface.metallic);//若金属度为1，specular为color，   若金属度为0，specular为0.04     这个值就是Ks
    brdf.perceptualRoughness =PerceptualSmoothnessToPerceptualRoughness(surface.smoothness);//1-perceptual smoothness
    brdf.roughness = PerceptualRoughnessToRoughness(brdf.perceptualRoughness);//对perceptual roughness平方
    brdf.fresnel = saturate(surface.smoothness + 1.0 - oneMinusReflectivity);//?
    return brdf;
}

#endif