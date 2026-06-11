using UnityEngine;
using UnityEngine.Rendering;

//让RP把光数据发送到GPU，原理上相当于是针对灯光的CameraRenderer
public class Lighting
{
    private const string bufferName = "_Lighting";
    
    CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };
    
    public void Setup(ScriptableRenderContext context)
    {
        buffer.BeginSample(bufferName);
        SetupDirectionalLight();
        buffer.EndSample(bufferName);
        context.ExecuteCommandBuffer(buffer);
        buffer.Clear();
    }

    static int dirLightColorId = Shader.PropertyToID("_DirectionalLightColor");
    static int dirLightDirectionId = Shader.PropertyToID("_DirectionalLightDirection");
    
    void SetupDirectionalLight()
    {
        Light light = RenderSettings.sun;//访问场景主光，默认用场景中最亮的定向光表示太阳，也可以在照明/环境/太阳源，手动配置   
        buffer.SetGlobalVector(dirLightColorId, light.color.linear * light.intensity);//注意linear，强度在这乘完了就不用在Light.hlsl单独放上强度的结构
        buffer.SetGlobalVector(dirLightDirectionId, - light.transform.forward);//一定注意是反向
    }
}
