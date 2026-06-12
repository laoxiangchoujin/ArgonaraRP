using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;

//让RP把光数据发送到GPU，原理上相当于是针对灯光的CameraRenderer
public class Lighting
{
    const int maxDirLightCount = 4; //最多4个方向光

    static int dirLightCountId = Shader.PropertyToID("_DirectionalLightCount");
    static int dirLightColorsId = Shader.PropertyToID("_DirectionalLightColors");
    static int dirLightDirectionsId = Shader.PropertyToID("_DirectionalLightDirections");
    
    static Vector4[] 
        dirLightColors = new Vector4[maxDirLightCount],//也就是四个定向光，总计四个颜色和方向，2*4*Vector4
        dirLightDirections = new Vector4[maxDirLightCount];//话说为啥不用vector3？
    
    private const string bufferName = "_Lighting";
    
    CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };

    private CullingResults cullingResults;
    
    public void Setup(ScriptableRenderContext context, CullingResults cullingResults)
    {
        this.cullingResults = cullingResults;//执行物体剔除的时候，unity会确定哪些灯光会影响相机可见的空间，so需要剔除结果，以更好支持多光源（当然就不只是多个平行光）
        buffer.BeginSample(bufferName);
        SetupLights();
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
        buffer.SetGlobalInt(dirLightCountId, visibleLights.Length);
        buffer.SetGlobalVectorArray(dirLightColorsId, dirLightColors);
        buffer.SetGlobalVectorArray(dirLightDirectionsId, dirLightDirections);
    }

    void SetupDirectionalLight(int index, ref VisibleLight visibleLight)//如果直接把visibleLight作为参数传给此函数，会复制出一个visibleLight，而这个类型结构非常大，用引用传参，避免如此的额外内存
    {
        dirLightColors[index] = visibleLight.finalColor;
        dirLightDirections[index] = -visibleLight.localToWorldMatrix.GetColumn(2);//方向，并且是反向
    }
}
