using UnityEngine;
using UnityEngine.Rendering;

namespace ArgonaraRP.Runtime.ArgonaraScene
{
	[System.Serializable]
	public class GPUDrivenTerrain
	{
		[System.NonSerialized] public GPUDrivenTerrainQuadTree quadTree;
		[System.NonSerialized] public Camera camera;

		// 需重建的旧值检测
		Vector3 prevPosition;
		float prevTerrainWidth;

		Vector3 position;
		float terrainWidth;
		Texture2D heightMap;
		float terrainMaxHeight;
		ComputeShader cs;
		Mesh[] lodMeshes;
		bool bShowDebug;
		bool enableFrustumCulling;
		bool enableTerrainRendering;

		const float patchSize = 8f;

		int kernelIndex;
		uint groupSizeX = 0;

		public struct Instance
		{
			public Vector3 pos;
			public Vector3 rot;
			public float sca;
		}
		public Instance[] allInstances;
		private int instanceCount;

		ComputeBuffer beforeProcessing;
		ComputeBuffer[] lodBuffers = new ComputeBuffer[8];
		ComputeBuffer[] argsBuffers = new ComputeBuffer[8];
		uint[][] argses = new uint[8][]
		{
			new uint[5] { 0, 0, 0, 0, 0 }, new uint[5] { 0, 0, 0, 0, 0 },
			new uint[5] { 0, 0, 0, 0, 0 }, new uint[5] { 0, 0, 0, 0, 0 },
			new uint[5] { 0, 0, 0, 0, 0 }, new uint[5] { 0, 0, 0, 0, 0 },
			new uint[5] { 0, 0, 0, 0, 0 }, new uint[5] { 0, 0, 0, 0, 0 },
		};

		Plane[] cullingPlanes;
		int patchNum;

		const string TerrainShaderName = "Argonara RP/Scene/Terrain";
		Material[] lodMats;

		public GPUDrivenTerrain(GPUDrivenTerrainProfile profile)
		{
			this.position = profile.position;
			this.terrainWidth = (float)profile.terrainWidth;
			this.heightMap = profile.heightMap;
			this.terrainMaxHeight = profile.terrainMaxHeight;
			this.cs = profile.terrainCS;
			this.lodMeshes = profile.lodMeshes;
			this.bShowDebug = profile.bShowDebug;
			this.enableFrustumCulling = profile.enableFrustumCulling;
			this.enableTerrainRendering = profile.enableTerrainRendering;

			camera = Camera.main;
			quadTree = new GPUDrivenTerrainQuadTree(camera, profile);

			prevPosition = position;
			prevTerrainWidth = terrainWidth;
		}

		public void Start()
		{
			quadTree.Start();

			kernelIndex = cs.FindKernel("CSMain");
			cs.GetKernelThreadGroupSizes(kernelIndex, out groupSizeX, out _, out _);

			patchNum = (int)(terrainWidth / patchSize);
			instanceCount = Mathf.CeilToInt((float)(patchNum * patchNum) / (float)groupSizeX) * (int)groupSizeX;

			var terrainShader = Shader.Find(TerrainShaderName);
			if (terrainShader != null)
			{
				lodMats = new Material[8];
				for (int i = 0; i < 8; i++)
				{
					lodMats[i] = new Material(terrainShader)
					{
						hideFlags = HideFlags.HideAndDontSave
					};
				}
			}
			else
			{
				Debug.LogError("未找到地形 Shader：" + TerrainShaderName);
			}

			InitInstance();
			InitBuffer();

			cs.SetTexture(kernelIndex, "heightMap", heightMap);
			cs.SetFloat("terrainWidth", terrainWidth);
			cs.SetFloat("heightMapWidth", heightMap.width);
			cs.SetFloat("_TerrainMaxHeight", terrainMaxHeight);
		}

		void InitInstance()
		{
			allInstances = new Instance[patchNum * patchNum];
			Vector3 leftDownStartPos = position - new Vector3(0.5f * patchNum * patchSize, 0, 0.5f * patchNum * patchSize);

			for (int i = 0; i < patchNum; i++)
				for (int j = 0; j < patchNum; j++)
				{
					int idx = i * patchNum + j;
					allInstances[idx].pos = leftDownStartPos + new Vector3(
						(j + 0.5f) * patchSize, 0, (i + 0.5f) * patchSize);
					allInstances[idx].rot = Vector3.zero;
					allInstances[idx].sca = 1;
				}
		}

		void InitBuffer()
		{
			beforeProcessing = new ComputeBuffer(instanceCount, 7 * sizeof(float));
			beforeProcessing.SetData(allInstances);

			for (int i = 0; i < 8; i++)
			{
				lodBuffers[i] = new ComputeBuffer(instanceCount, 7 * sizeof(float), ComputeBufferType.Append);
				lodBuffers[i].SetCounterValue(0);

				argses[i][0] = (uint)lodMeshes[i].GetIndexCount(0);
				argsBuffers[i] = new ComputeBuffer(instanceCount, 5 * sizeof(uint), ComputeBufferType.IndirectArguments);
				argsBuffers[i].SetData(argses[i]);
			}
		}

		public void Update(GPUDrivenTerrainProfile profile)
		{
			// 检测 terrainWidth 变化 → 重建
			if (terrainWidth != (float)profile.terrainWidth)
			{
				Rebuild(profile);
				return;
			}

			// 位置变化 → 平移所有 patch 并重传
			if (position != profile.position)
			{
				Vector3 delta = profile.position - position;
				position = profile.position;
				for (int i = 0; i < patchNum * patchNum; i++)
					allInstances[i].pos += delta;
				beforeProcessing.SetData(allInstances);
			}

			// 实时同步轻量参数
			enableFrustumCulling = profile.enableFrustumCulling;
			enableTerrainRendering = profile.enableTerrainRendering;
			bShowDebug = profile.bShowDebug;
			quadTree.SyncLiveParameters(profile);

			if (heightMap != profile.heightMap)
			{
				heightMap = profile.heightMap;
				cs.SetTexture(kernelIndex, "heightMap", heightMap);
			}
			terrainMaxHeight = profile.terrainMaxHeight;

			quadTree.Update();

			cullingPlanes = GeometryUtility.CalculateFrustumPlanes(camera);
			cs.SetVectorArray("cullingPlanes", SixPlanes(cullingPlanes));
			cs.SetInt("patchCount", patchNum * patchNum);
			cs.SetInt("_EnableFrustumCulling", enableFrustumCulling ? 1 : 0);

			ResetBuffer();
			cs.Dispatch(kernelIndex, instanceCount / (int)groupSizeX, 1, 1);

			for (int i = 0; i < 8; i++)
			{
				ComputeBuffer.CopyCount(lodBuffers[i], argsBuffers[i], sizeof(uint));
				lodMats[i].SetBuffer("afterCulling", lodBuffers[i]);
				lodMats[i].SetFloat("_LodIndex", i);
				lodMats[i].SetTexture("_HeightMap", heightMap);
				lodMats[i].SetFloat("_TerrainWidth", terrainWidth);
				lodMats[i].SetFloat("_TerrainMaxHeight", terrainMaxHeight);
				if (bShowDebug)
					lodMats[i].EnableKeyword("_USE_DEBUG");
				else
					lodMats[i].DisableKeyword("_USE_DEBUG");
			}

			if (enableTerrainRendering)
			{
				for (int i = 0; i < 8; i++)
				{
					Graphics.DrawMeshInstancedIndirect(lodMeshes[i], 0, lodMats[i],
						new Bounds(position, new Vector3(5000f, 5000, 5000)), argsBuffers[i]);
				}
			}
		}

		void Rebuild(GPUDrivenTerrainProfile profile)
		{
			Dispose();
			position = profile.position;
			terrainWidth = (float)profile.terrainWidth;
			heightMap = profile.heightMap;
			terrainMaxHeight = profile.terrainMaxHeight;
			cs = profile.terrainCS;
			lodMeshes = profile.lodMeshes;
			camera = Camera.main;
			quadTree = new GPUDrivenTerrainQuadTree(camera, profile);
			Start();
		}

		Vector4[] SixPlanes(Plane[] planes)
		{
			Vector4[] result = new Vector4[6];
			for (int i = 0; i < 6; i++)
				result[i] = new Vector4(planes[i].normal.x, planes[i].normal.y, planes[i].normal.z, planes[i].distance);
			return result;
		}

		void ResetBuffer()
		{
			cs.SetBuffer(kernelIndex, "beforeCulling", beforeProcessing);
			cs.SetBuffer(kernelIndex, "quadTreeFinalBuffer", quadTree.appendFinalBuffer);

			int realCount = GetAppendBufferNodesCount(quadTree.appendFinalBuffer);
			if (bShowDebug)
				Debug.Log("terrain接收的-qdtree的node数量: " + realCount);
			cs.SetInt("quadTreeFinalCount", realCount);

			ClearLodBuffer();
		}

		int GetAppendBufferNodesCount(ComputeBuffer cb)
		{
			ComputeBuffer counterBuffer = new ComputeBuffer(1, sizeof(int), ComputeBufferType.Raw);
			int[] data = new int[1];
			ComputeBuffer.CopyCount(cb, counterBuffer, 0);
			counterBuffer.GetData(data);
			counterBuffer.Dispose();
			return data[0];
		}

		void ClearLodBuffer()
		{
			for (int i = 0; i < 8; i++)
			{
				lodBuffers[i].SetCounterValue(0);
				cs.SetBuffer(kernelIndex, "lod" + i + "Buffer", lodBuffers[i]);
			}
		}

		public void Dispose()
		{
			quadTree.Dispose();
			beforeProcessing?.Dispose();
			for (int i = 0; i < 8; i++)
			{
				lodBuffers[i]?.Dispose();
				argsBuffers[i]?.Dispose();
				if (lodMats != null && lodMats[i] != null)
				{
					if (Application.isPlaying) Object.Destroy(lodMats[i]);
					else Object.DestroyImmediate(lodMats[i]);
				}
			}
		}
	}

	public enum PowerOfTwo
	{
		_0 = 1, _1 = 2, _2 = 4, _3 = 8, _4 = 16,
		_5 = 32, _6 = 64, _7 = 128, _8 = 256, _9 = 512,
		_10 = 1024, _11 = 2048, _12 = 4096,
	}
}
