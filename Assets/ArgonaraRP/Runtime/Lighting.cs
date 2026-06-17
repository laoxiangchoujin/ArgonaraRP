using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;

//让RP把光数据发送到GPU，原理上相当于是针对灯光的CameraRenderer
public class Lighting
{
    const int maxDirLightCount = 4; //最多4个方向光

    static int dirLightCountId = Shader.PropertyToID("_DirectionalLightCount"),
                dirLightColorsId = Shader.PropertyToID("_DirectionalLightColors"),
                dirLightDirectionsId = Shader.PropertyToID("_DirectionalLightDirections"),
                dirLightShadowDataId = Shader.PropertyToID("_DirectionalLightShadowData");//x是阴影强度，y是每个定向光的初始tile位置，如4光*4级联，第一个光的这个y是0，第二个光的是4，8，12
    
    static Vector4[] 
        dirLightColors = new Vector4[maxDirLightCount],//也就是四个定向光，总计四个颜色和方向，2*4*Vector4
        dirLightDirections = new Vector4[maxDirLightCount],//话说为啥不用vector3？
        dirLightShadowData = new Vector4[maxDirLightCount];//怎么不是vector2？
    
    private const string bufferName = "_Lighting";
    
    CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };

    private CullingResults cullingResults;
    
    Shadows shadows = new Shadows();//Lighting管理Shadows的一个实例
    
    public void Setup(ScriptableRenderContext context, CullingResults cullingResults, 
        ShadowSettings shadowSettings)
    {
        this.cullingResults = cullingResults;//执行物体剔除的时候，unity会确定哪些灯光会影响相机可见的空间，so需要剔除结果，以更好支持多光源（当然就不只是多个平行光）
        buffer.BeginSample(bufferName);
        shadows.Setup(context, cullingResults, shadowSettings);//调用初始化阴影
        SetupLights();
        shadows.Render(); //上一行在定义光的时候，看谁要生成阴影，这里渲染
        buffer.EndSample(bufferName);
        context.ExecuteCommandBuffer(buffer);
        buffer.Clear();
    }

    
    
    void SetupLights()
    {
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;//可见光，是专门的类型数组
        int dirLightCount = 0;
        for (int i = 0; i < visibleLights.Length; i++)
        {
            VisibleLight visibleLight = visibleLights[i];//这里边获得的光不一定什么类型的，得判断
            if (visibleLight.lightType == LightType.Directional)
            {
                SetupDirectionalLight(dirLightCount++, ref visibleLight);
                if (dirLightCount >= maxDirLightCount) //实际场景里平行光数量可能超过4个，咱们只截取前四个
                {
                    break;
                }
            }
        }
        
        //向global缓冲区发送平行光数量，所有平行光颜色和方向
        buffer.SetGlobalInt(dirLightCountId, dirLightCount);
        buffer.SetGlobalVectorArray(dirLightColorsId, dirLightColors);
        buffer.SetGlobalVectorArray(dirLightDirectionsId, dirLightDirections);
        buffer.SetGlobalVectorArray(dirLightShadowDataId, dirLightShadowData);
        //Debug.Log($"dirLightCount={dirLightCount}, visibleLights.Length={visibleLights.Length}");
    }

    void SetupDirectionalLight(int index, ref VisibleLight visibleLight)//如果直接把visibleLight作为参数传给此函数，会复制出一个visibleLight，而这个类型结构非常大，用引用传参，避免如此的额外内存
    {
        dirLightColors[index] = visibleLight.finalColor;
        dirLightDirections[index] = -visibleLight.localToWorldMatrix.GetColumn(2);//方向，并且是反向
        dirLightShadowData[index] = shadows.ReserveDirectionalShadows(visibleLight.light, index);//对每一盏定向光，尝试为其保存阴影，顺便获取阴影强度和偏移
    }

    public void Cleanup()
    {
        shadows.Cleanup();
    }
}
