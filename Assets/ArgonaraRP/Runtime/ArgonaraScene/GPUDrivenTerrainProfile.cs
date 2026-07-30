using UnityEngine;

namespace ArgonaraRP.Runtime.ArgonaraScene
{
	[CreateAssetMenu(fileName = "GPUDrivenTerrainProfile", menuName = "Rendering/Scene/GPUDrivenTerrainProfile")]
	public class GPUDrivenTerrainProfile : ScriptableObject
	{
		[Header("共有")]
		public Vector3 position;
		public PowerOfTwo terrainWidth = PowerOfTwo._10;
		public float patchSize = 8f;
		public int maxLodLevels = 8;
		public bool enableFrustumCulling = true;

		[Header("地形")]
		public ComputeShader terrainCS;
		public Mesh[] lodMeshes = new Mesh[8];
		public Texture2D heightMap;
		public float terrainMaxHeight = 512f;
		public bool enableTerrainRendering = true;
		public bool bShowDebug = false;

		[Header("四叉树")]
		public ComputeShader quadTreeCS;
		public Mesh quadTreeDebugMesh;
		[Range(0.5f, 3f)] public float subDivideStrength = 1f;
		public int firstCutNum = 4;
		public bool bVisualizeNodes = false;
		public bool bShowConsoleDebug = false;

		
	}
}
