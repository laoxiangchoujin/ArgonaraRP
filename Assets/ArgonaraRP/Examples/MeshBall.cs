using UnityEngine;

public class MeshBall : MonoBehaviour
{
    static int baseColorId = Shader.PropertyToID("_BaseColor");

    [SerializeField] private Mesh mesh = default;
    [SerializeField] Material material = default;
    
    //实例化，要transform矩阵和各自的属性
    Matrix4x4[] matrices = new Matrix4x4[1023];//好像是说实例化一次最多整1023个，是这样吗？
    Vector4[] baseColors = new Vector4[1023];
    
    MaterialPropertyBlock block;

    void Awake()
    {
        for (int i = 0; i < matrices.Length; i++)
        {
            matrices[i] = Matrix4x4.TRS(Random.insideUnitSphere * 10f, Quaternion.identity, Vector3.one);//矩阵的TRS函数，用pos、quateration、scale生成一个矩阵
            baseColors[i] = new Vector4(Random.value, Random.value, Random.value, 1f);
        }
    }

    void Update()
    {
        if (block == null)
        {
            block = new MaterialPropertyBlock();
            block.SetVectorArray(baseColorId, baseColors);
        }
            
        Graphics.DrawMeshInstanced(mesh,0,material,matrices,matrices.Length,block);
    }
}
