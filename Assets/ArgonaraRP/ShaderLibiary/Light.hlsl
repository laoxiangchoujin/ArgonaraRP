#ifndef CUSTOM_LIGHT_INCLUDED
#define CUSTOM_LIGHT_INCLUDED

CBUFFER_START(_CustomLight)
    float3 _DirectionalLightColor;
    float3 _DirectionalLightDirection;
CBUFFER_END

struct Light {//就是平行光
    float3 color;
    float3 direction;
};

Light GetDirectionalLight ()
{
    Light light;
    light.color = _DirectionalLightColor;
    light.direction = _DirectionalLightDirection;//光的方向是指向光源的，而非光的去向
    return light;
}

#endif