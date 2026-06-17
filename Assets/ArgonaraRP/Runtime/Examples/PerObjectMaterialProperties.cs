using UnityEngine;

[DisallowMultipleComponent]//意思是，一个对象上只能放一个同类型脚本
//当创建很多物体，又懒得创建很多材质，我只想改它们的一个参数，那就这样用MaterialPropertyBlock来实现吧
//另外，SRP batcher是把材质的属性缓存在GPU中，用MPB去运行时动态覆盖材质属性，而会导致SRP batcher失效
public class PerObjectMaterialProperties : MonoBehaviour
{

    static int baseColorId = Shader.PropertyToID("_BaseColor"),
        cutoffId = Shader.PropertyToID("_Cutoff"),
        metallicId = Shader.PropertyToID("_Metallic"),
        smoothnessId = Shader.PropertyToID("_Smoothness"),
        emissionColorId = Shader.PropertyToID("_EmissionColor");
        

    [SerializeField] Color baseColor = Color.white;
    [SerializeField,Range(0f,1f)]
    float alphaCutoff = 0.5f, metallic = 0f, smoothness = 0.5f;

    [SerializeField, ColorUsage(false, true)]//后半个是，不显示alpha通道，启用hdr值
    Color emissionColor = Color.black;

    static MaterialPropertyBlock block;//希望所有此脚本的实例对象都复用同一个block，所以用static

    void OnValidate()
    {
        if(block == null)
            block = new MaterialPropertyBlock();
        block.SetColor(baseColorId, baseColor);
        block.SetFloat(cutoffId, alphaCutoff);
        block.SetFloat(metallicId, metallic);
        block.SetFloat(smoothnessId, smoothness);
        block.SetColor(emissionColorId, emissionColor);
        GetComponent<Renderer>().SetPropertyBlock(block);
    }

    void Awake()
    {
        OnValidate();//说是因为OnValidate不会在打包的程序中调用，所以就这样把它放进awake里（说是不会调用，那应该OnValidate()不会被删掉）
    }
}