using UnityEngine;
using UnityEngine.Rendering;

public class MeshBall : MonoBehaviour
{
    static int baseColorId = Shader.PropertyToID("_BaseColor"),
    metallicId = Shader.PropertyToID("_Metallic"),
    smoothnessId = Shader.PropertyToID("_Smoothness");

    [SerializeField] private Mesh mesh = default;
    [SerializeField] Material material = default;
    
    //实例化，要transform矩阵和各自的属性
    Matrix4x4[] matrices = new Matrix4x4[1023];//好像是说实例化一次最多整1023个，是这样吗？
    Vector4[] baseColors = new Vector4[1023];
    float[]
        metallic = new float[1023],
        smoothness = new float[1023];

    
    MaterialPropertyBlock block;

    void Awake()
    {
        for (int i = 0; i < matrices.Length; i++)
        {
            matrices[i] = Matrix4x4.TRS(Random.insideUnitSphere * 10f, Quaternion.identity, Vector3.one);//矩阵的TRS函数，用pos、quateration、scale生成一个矩阵
            baseColors[i] = new Vector4(Random.value, Random.value, Random.value, 1f);
            metallic[i] = Random.value < 0.25f ? 1f : 0f;//暂且让25%的材质有金属感
            smoothness[i] = Random.Range(0.05f, 0.95f);
        }
    }

    [SerializeField] LightProbeProxyVolume lightProbeVolume = null;
    LightProbeProxyVolume storedPrevVolume;
    
    void Update()
    {
        if (block == null || lightProbeVolume != storedPrevVolume)
        {
            storedPrevVolume = lightProbeVolume;
            block = new MaterialPropertyBlock();
            block.SetVectorArray(baseColorId, baseColors);
            block.SetFloatArray(metallicId, metallic);
            block.SetFloatArray(smoothnessId, smoothness);

            if (!lightProbeVolume)
            {
                var positions = new Vector3[1023]; //要为每个实例生成一个light probe，需要位置
                for (int i = 0; i < matrices.Length; i++)
                {
                    positions[i] = matrices[i].GetColumn(3);
                }

                var lightProbes = new SphericalHarmonicsL2[1023];
                LightProbes.CalculateInterpolatedLightAndOcclusionProbes(positions, lightProbes,
                    null); //从已烘焙的探针数据里插值查询，场景里必须有烘焙过的 Light Probe Group，否则这个函数查到的是空数据，返回全零
                block.CopySHCoefficientArraysFrom(
                    lightProbes); //将lightProbes的数据复制到block中//UnityPerDraw 变成数组，1023 个球 → 1023 组 unity_SHAr...unity_SHC，
            }
        }
            
        Graphics.DrawMeshInstanced(mesh,0,material,matrices,matrices.Length,block,
            ShadowCastingMode.On, true, 0, null,
            lightProbeVolume ? LightProbeUsage.UseProxyVolume : LightProbeUsage.CustomProvided,
            lightProbeVolume);
    }
}
