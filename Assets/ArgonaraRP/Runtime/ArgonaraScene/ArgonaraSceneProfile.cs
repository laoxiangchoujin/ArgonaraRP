using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace ArgonaraRP.Runtime.ArgonaraScene
{
	//[CreateAssetMenu(fileName = "ArgonaraSceneProfile", menuName = "Rendering/Scene/ArgonaraSceneProfile")]
	//[ExecuteAlways]
	public class ArgonaraSceneProfile : MonoBehaviour
	{
		public GPUDrivenTerrainProfile terrainProfile; // Asset 引用（ScriptableObject 或普通 SO）
		public GPUDrivenTerrain terrain; // [Serializable] 运行时对象

		void Start()
		{
			if (terrainProfile != null)
			{
				terrain = new GPUDrivenTerrain(terrainProfile);
				terrain.Start();
			}
				
		}

		void Update()
		{
			if (terrain != null)
			{
				terrain.Update(terrainProfile);
			}
				
		}

		void OnDestroy()
		{
			terrain?.Dispose();
		}
	}
} 

