using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;

//让RP把光数据发送到GPU，原理上相当于是针对灯光的CameraRenderer
public class Lighting
{
    const int maxDirLightCount = 4, maxOtherLightCount = 64; //最多4个方向光

    static int dirLightCountId = Shader.PropertyToID("_DirectionalLightCount"),
                dirLightColorsId = Shader.PropertyToID("_DirectionalLightColors"),
                dirLightDirectionsId = Shader.PropertyToID("_DirectionalLightDirections"),
                dirLightShadowDataId = Shader.PropertyToID("_DirectionalLightShadowData");//x是阴影强度，y是每个定向光的初始tile位置，如4光*4级联，第一个光的这个y是0，第二个光的是4，8，12
    
    static Vector4[] 
        dirLightColors = new Vector4[maxDirLightCount],//也就是四个定向光，总计四个颜色和方向，2*4*Vector4
        dirLightDirections = new Vector4[maxDirLightCount],//话说为啥不用vector3？
        dirLightShadowData = new Vector4[maxDirLightCount];//怎么不是vector2？
    
    
    //------点光和聚光------//
    static int
        otherLightCountId = Shader.PropertyToID("_OtherLightCount"),
        otherLightColorsId = Shader.PropertyToID("_OtherLightColors"),
        otherLightPositionsId = Shader.PropertyToID("_OtherLightPositions"),
        otherLightDirectionsId = Shader.PropertyToID("_OtherLightDirections"),//聚光灯需要方向
        otherLightSpotAnglesId = Shader.PropertyToID("_OtherLightSpotAngles"),//聚光灯聚光角
        otherLightShadowDataId = Shader.PropertyToID("_OtherLightShadowData");

    static Vector4[]
        otherLightColors = new Vector4[maxOtherLightCount],
        otherLightPositions = new Vector4[maxOtherLightCount],
        otherLightDirections = new Vector4[maxOtherLightCount],
        otherLightSpotAngles = new Vector4[maxOtherLightCount],
        otherLightShadowData = new Vector4[maxOtherLightCount];
    
    private const string bufferName = "_Lighting";
    
    CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };

    private CullingResults cullingResults;
    
    Shadows shadows = new Shadows();//Lighting管理Shadows的一个实例
    
    public void Setup(ScriptableRenderContext context, CullingResults cullingResults, 
        ShadowSettings shadowSettings, bool useLightsPerObject)
    {
        this.cullingResults = cullingResults;//执行物体剔除的时候，unity会确定哪些灯光会影响相机可见的空间，so需要剔除结果，以更好支持多光源（当然就不只是多个平行光）
        buffer.BeginSample(bufferName);
        shadows.Setup(context, cullingResults, shadowSettings);//调用初始化阴影
        SetupLights(useLightsPerObject);
        shadows.Render(); //上一行在定义光的时候，看谁要生成阴影，这里渲染
        buffer.EndSample(bufferName);
        context.ExecuteCommandBuffer(buffer);
        buffer.Clear();
    }

    static string lightsPerObjectKeyword = "_LIGHTS_PER_OBJECT";
    
    void SetupLights(bool useLightsPerObject)
    {
        NativeArray<int> indexMap = useLightsPerObject ? cullingResults.GetLightIndexMap(Allocator.Temp) : default;//Unity内部所有参与剔除的灯光索引表，包括不可见灯光
        NativeArray<VisibleLight> visibleLights = cullingResults.visibleLights;//可见光，是专门的类型数组
        int dirLightCount = 0, otherLightCount = 0;
        int i;
        for (i = 0; i < visibleLights.Length; i++)
        {
            int newIndex = -1;
            VisibleLight visibleLight = visibleLights[i];//这里边获得的光不一定什么类型的，得判断
            
            switch (visibleLight.lightType)
            {
                case LightType.Directional:
                    if (dirLightCount < maxDirLightCount)
                    {
                        SetupDirectionalLight(dirLightCount++, ref visibleLight);
                    }
                    break;
                case LightType.Point:
                    if (otherLightCount < maxOtherLightCount)
                    {
                        newIndex = otherLightCount;
                        SetupPointLight(otherLightCount++, ref visibleLight);
                    }
                    break;
                case LightType.Spot:
                    if (otherLightCount < maxOtherLightCount)
                    {
                        newIndex = otherLightCount;
                        SetupSpotLight(otherLightCount++, ref visibleLight);
                    }
                    break;
            }
            if (useLightsPerObject)
            {
                indexMap[i] = newIndex;//在遍历所有光的循环里，这个i是其中一盏灯，如果它是point/spot，给这个other light的索引++，把visible light的unity内部index映射到我srp的other light index
            }
        }

        if (useLightsPerObject)//上边已经取出了point和spot light的索引，消除了定向光和rect光，then消除不可见光的索引，也就是index > 可见光index的，也在indexMap里的不可见光。被消除的，索引都设为了-1
        {
            for (; i < indexMap.Length; i++)//i从上一个循环继续++
            {
                indexMap[i] = -1;
            }

            cullingResults.SetLightIndexMap(indexMap);//只剩下点光源和聚光灯的新索引
            //此时，经过unity内部计算，unity_LightData 和 unity_LightIndices 就神奇地有数据了，Unity 一直在做逐物体的灯光裁剪，这里经过翻译变成自己的编号，可以正确拿到逐物体的“受几个，哪几个灯光的影响”的数据
            indexMap.Dispose();
            Shader.EnableKeyword(lightsPerObjectKeyword);
        }
        else
        {
            Shader.DisableKeyword(lightsPerObjectKeyword);
        }
        
        //定向光，向global缓冲区发送
        buffer.SetGlobalInt(dirLightCountId, dirLightCount);
        if (dirLightCount > 0)
        {
            buffer.SetGlobalVectorArray(dirLightColorsId, dirLightColors);
            buffer.SetGlobalVectorArray(dirLightDirectionsId, dirLightDirections);
            buffer.SetGlobalVectorArray(dirLightShadowDataId, dirLightShadowData);
        }

        //点光源、聚光
        buffer.SetGlobalInt(otherLightCountId, otherLightCount);
        if (otherLightCount > 0)
        {
            buffer.SetGlobalVectorArray(otherLightColorsId, otherLightColors);
            buffer.SetGlobalVectorArray(otherLightPositionsId, otherLightPositions);
            buffer.SetGlobalVectorArray(otherLightDirectionsId, otherLightDirections);
            buffer.SetGlobalVectorArray(otherLightSpotAnglesId, otherLightSpotAngles);
            buffer.SetGlobalVectorArray(otherLightShadowDataId, otherLightShadowData);
        }
    }

    void SetupDirectionalLight(int index, ref VisibleLight visibleLight)//如果直接把visibleLight作为参数传给此函数，会复制出一个visibleLight，而这个类型结构非常大，用引用传参，避免如此的额外内存
    {
        dirLightColors[index] = visibleLight.finalColor;
        dirLightDirections[index] = -visibleLight.localToWorldMatrix.GetColumn(2);//方向，并且是反向
        dirLightShadowData[index] = shadows.ReserveDirectionalShadows(visibleLight.light, index);//对每一盏定向光，尝试为其保存阴影，顺便获取阴影强度和偏移
    }

    void SetupPointLight(int index, ref VisibleLight visibleLight)
    {
        otherLightColors[index] = visibleLight.finalColor;
        Vector4 position = visibleLight.localToWorldMatrix.GetColumn(3);
        position.w = 1f / Mathf.Max(visibleLight.range * visibleLight.range, 0.00001f);//1/(range*range)，省shader除法
        otherLightPositions[index] = position;
        otherLightSpotAngles[index] = new Vector4(0f, 1f);
        Light light = visibleLight.light;
        otherLightShadowData[index] = shadows.ReserveOtherShadows(light, index);
    }

    void SetupSpotLight(int index, ref VisibleLight visibleLight)
    {
        otherLightColors[index] = visibleLight.finalColor;
        Vector4 position = visibleLight.localToWorldMatrix.GetColumn(3);
        position.w = 1f / Mathf.Max(visibleLight.range * visibleLight.range, 0.00001f);
        otherLightPositions[index] = position;
        otherLightDirections[index] = -visibleLight.localToWorldMatrix.GetColumn(2);//依旧指向光源

        Light light = visibleLight.light;
        float innerCos = Mathf.Cos(Mathf.Deg2Rad * 0.5f * light.innerSpotAngle);//内角属性不在visibleLight中
        float outerCos = Mathf.Cos(Mathf.Deg2Rad * 0.5f * visibleLight.spotAngle);
        float angleRangeInv = 1f / Mathf.Max(innerCos - outerCos, 0.001f);
        otherLightSpotAngles[index] = new Vector4(angleRangeInv, -outerCos * angleRangeInv);
        otherLightShadowData[index] = shadows.ReserveOtherShadows(light, index);
    }
    
    public void Cleanup()
    {
        shadows.Cleanup();
    }
}
