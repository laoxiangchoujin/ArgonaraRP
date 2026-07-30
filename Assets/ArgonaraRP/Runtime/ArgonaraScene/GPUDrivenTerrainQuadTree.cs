using UnityEngine;

namespace ArgonaraRP.Runtime.ArgonaraScene
{
	[System.Serializable]
	public class GPUDrivenTerrainQuadTree
	{
		Vector3 position;
		float terrainWidth;
		int maxLodLevels;
		int firstCutNum;
		float subdivideStrength;
		bool bVisualizeNodes;
		bool bShowConsoleDebug;
		bool enableFrustumCulling;
		bool prevFrustumCulling;

		ComputeShader quadTreeCS;
		Mesh visualizationMesh;

		[System.NonSerialized] public Camera camera;

		int kernelIndex;
		uint groupSizeX;

		public struct Node
		{
			public Vector3 pos;
			public Vector2Int indexxy;
			public float width;
			public int lodLevel;
		}
		public Node[] allNodes;
		int instanceCount;
		public int toAddNodeCount;

		ComputeBuffer initBuffer;
		ComputeBuffer bufferA;
		ComputeBuffer bufferB;
		public bool bUseBufferAAsConsume = true;

		Vector3 camPos;
		Vector3 camRot;
		Plane[] cullingPlanes = new Plane[6];

		public ComputeBuffer appendFinalBuffer;

		const string QuadTreeShaderName = "Argonara RP/Scene/Terrain QuadTree Visualization";
		Material visualizationMaterial;
		ComputeBuffer args0Buffer;
		uint[] args0 = new uint[5] { 0, 0, 0, 0, 0 };

		public GPUDrivenTerrainQuadTree(Camera camera, GPUDrivenTerrainProfile profile)
		{
			this.camera = camera;
			this.position = profile.position;
			this.terrainWidth = (float)profile.terrainWidth;
			this.maxLodLevels = profile.maxLodLevels;
			this.firstCutNum = profile.firstCutNum;
			this.subdivideStrength = profile.subDivideStrength;
			this.bVisualizeNodes = profile.bVisualizeNodes;
			this.bShowConsoleDebug = profile.bShowConsoleDebug;
			this.quadTreeCS = profile.quadTreeCS;
			this.visualizationMesh = profile.quadTreeDebugMesh;

			if (visualizationMesh == null)
				visualizationMesh = Resources.GetBuiltinResource<Mesh>("Cube.fbx");
		}

		public void Start()
		{
			if (camera == null)
			{
				Debug.LogError("GPUDrivenTerrainQuadTree camera is null");
				Dispose();
				return;
			}

			kernelIndex = quadTreeCS.FindKernel("QuadTreeCSMain");
			quadTreeCS.GetKernelThreadGroupSizes(kernelIndex, out groupSizeX, out _, out _);
			instanceCount = Mathf.CeilToInt((float)(firstCutNum * firstCutNum) / (float)groupSizeX) * (int)groupSizeX;

			var shader = Shader.Find(QuadTreeShaderName);
			if (shader != null)
			{
				visualizationMaterial = new Material(shader)
				{
					hideFlags = HideFlags.HideAndDontSave
				};
			}
			else
			{
				Debug.LogWarning("未找到四叉树可视化 Shader：" + QuadTreeShaderName);
			}

			InitNodes();
			InitBuffers();

			CopyInitBuffer();
			quadTreeCS.SetBuffer(kernelIndex, "consumeNodeBuffer", bufferA);
			quadTreeCS.SetBuffer(kernelIndex, "appendNodeBuffer", bufferB);
		}

		public void SyncLiveParameters(GPUDrivenTerrainProfile profile)
		{
			enableFrustumCulling = profile.enableFrustumCulling;
			subdivideStrength = profile.subDivideStrength;
			bVisualizeNodes = profile.bVisualizeNodes;
			bShowConsoleDebug = profile.bShowConsoleDebug;

			// 检测 firstCutNum 或 terrainWidth 变化 → 重建
			if (firstCutNum != profile.firstCutNum || terrainWidth != (float)profile.terrainWidth)
			{
				firstCutNum = profile.firstCutNum;
				terrainWidth = (float)profile.terrainWidth;
				RestartQdtree();
				return;
			}

			// 位置变化 → 平移所有 node 并重传
			if (position != profile.position)
			{
				Vector3 delta = profile.position - position;
				position = profile.position;
				for (int i = 0; i < firstCutNum * firstCutNum; i++)
					allNodes[i].pos += delta;
				initBuffer.SetData(allNodes);
				RestartQdtree();
			}
		}

		void InitNodes()
		{
			allNodes = new Node[instanceCount];
			Vector3 leftDownStartPos = position - new Vector3(0.5f * terrainWidth, 0, 0.5f * terrainWidth);
			float nodeWidth = terrainWidth / firstCutNum;
			int startLod = maxLodLevels - 1;

			for (int i = 0; i < firstCutNum; i++)
				for (int j = 0; j < firstCutNum; j++)
				{
					int idx = i * firstCutNum + j;
					allNodes[idx].pos = leftDownStartPos + new Vector3(
						(j + 0.5f) * nodeWidth, 0, (i + 0.5f) * nodeWidth);
					allNodes[idx].indexxy = new Vector2Int(i, j);
					allNodes[idx].width = nodeWidth;
					allNodes[idx].lodLevel = startLod;
				}
		}

		void InitBuffers()
		{
			initBuffer = new ComputeBuffer(instanceCount, 7 * sizeof(float));
			initBuffer.SetData(allNodes);

			bufferA = new ComputeBuffer(instanceCount, 7 * sizeof(float), ComputeBufferType.Append);
			bufferA.SetCounterValue(0);
			bufferB = new ComputeBuffer(instanceCount, 7 * sizeof(float), ComputeBufferType.Append);
			bufferB.SetCounterValue(0);

			appendFinalBuffer = new ComputeBuffer(instanceCount * firstCutNum, 7 * sizeof(float), ComputeBufferType.Append);
			appendFinalBuffer.SetCounterValue(0);
			quadTreeCS.SetBuffer(kernelIndex, "appendFinalList", appendFinalBuffer);

			if (visualizationMesh != null)
				args0[0] = (uint)visualizationMesh.GetIndexCount(0);
			args0Buffer = new ComputeBuffer(instanceCount * firstCutNum, 5 * sizeof(uint), ComputeBufferType.IndirectArguments);
			args0Buffer.SetData(args0);

			toAddNodeCount = firstCutNum * firstCutNum;
			quadTreeCS.SetInt("consumeBufferCount", toAddNodeCount);
		}

		void CopyInitBuffer()
		{
			int copyKernelIndex = quadTreeCS.FindKernel("CopyInitBuffer");
			quadTreeCS.SetBuffer(copyKernelIndex, "InitBuffer", initBuffer);
			quadTreeCS.SetBuffer(copyKernelIndex, "consumeNodeBuffer", bufferA);
			int count = firstCutNum * firstCutNum;
			quadTreeCS.SetInt("initNodeCount", count);
			quadTreeCS.Dispatch(copyKernelIndex, Mathf.CeilToInt(count / (float)groupSizeX), 1, 1);
		}

		//==================== 每帧更新 ====================
		public void Update()
		{
			cullingPlanes = GeometryUtility.CalculateFrustumPlanes(camera);
			quadTreeCS.SetVectorArray("cullingPlanes", SixPlanes(cullingPlanes));

			if (camPos != camera.transform.position || camRot != camera.transform.rotation.eulerAngles)
			{
				RestartQdtree();
			}

			camPos = camera.transform.position;
			camRot = camera.transform.rotation.eulerAngles;
			quadTreeCS.SetVector("camPos", camPos);
			quadTreeCS.SetFloat("subdivideStrength", subdivideStrength);
			quadTreeCS.SetInt("_EnableFrustumCulling", enableFrustumCulling ? 1 : 0);

			if (enableFrustumCulling != prevFrustumCulling)
			{
				prevFrustumCulling = enableFrustumCulling;
				RestartQdtree();
			}

			instanceCount = Mathf.CeilToInt((float)(toAddNodeCount) / (float)groupSizeX) * (int)groupSizeX;
			instanceCount = Mathf.Max(instanceCount, (int)groupSizeX);
			quadTreeCS.Dispatch(kernelIndex, instanceCount / (int)groupSizeX, 1, 1);

			UpdateBuffers();
			DebugVisualization();
		}

		Vector4[] SixPlanes(Plane[] planes)
		{
			Vector4[] result = new Vector4[6];
			for (int i = 0; i < 6; i++)
				result[i] = new Vector4(planes[i].normal.x, planes[i].normal.y, planes[i].normal.z, planes[i].distance);
			return result;
		}

		void UpdateBuffers()
		{
			if (bUseBufferAAsConsume)
			{
				toAddNodeCount = GetAppendBufferNodesCount(bufferB);
				quadTreeCS.SetInt("consumeBufferCount", toAddNodeCount);
				quadTreeCS.SetBuffer(kernelIndex, "consumeNodeBuffer", bufferB);
				quadTreeCS.SetBuffer(kernelIndex, "appendNodeBuffer", bufferA);
				bufferA.SetCounterValue(0);
				bUseBufferAAsConsume = false;
			}
			else
			{
				toAddNodeCount = GetAppendBufferNodesCount(bufferA);
				quadTreeCS.SetInt("consumeBufferCount", toAddNodeCount);
				quadTreeCS.SetBuffer(kernelIndex, "consumeNodeBuffer", bufferA);
				quadTreeCS.SetBuffer(kernelIndex, "appendNodeBuffer", bufferB);
				bufferB.SetCounterValue(0);
				bUseBufferAAsConsume = true;
			}
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

		void DebugVisualization()
		{
			if (bShowConsoleDebug)
			{
				int count = GetAppendBufferNodesCount(appendFinalBuffer);
				Debug.Log("appendFinalList的数量是" + count);
			}

			if (bVisualizeNodes && visualizationMaterial != null && visualizationMesh != null)
			{
				ComputeBuffer.CopyCount(appendFinalBuffer, args0Buffer, sizeof(uint));
				visualizationMaterial.SetBuffer("afterCulling", appendFinalBuffer);
				Graphics.DrawMeshInstancedIndirect(visualizationMesh, 0, visualizationMaterial,
					new Bounds(position, new Vector3(1000f, 1000, 1000)), args0Buffer);
			}
		}

		public void Dispose()
		{
			if (visualizationMaterial != null)
			{
				if (Application.isPlaying) Object.Destroy(visualizationMaterial);
				else Object.DestroyImmediate(visualizationMaterial);
				visualizationMaterial = null;
			}
			initBuffer?.Dispose();
			bufferA?.Dispose();
			bufferB?.Dispose();
			appendFinalBuffer?.Dispose();
			args0Buffer?.Dispose();
		}

		void RestartQdtree()
		{
			Dispose();
			Start();
			bUseBufferAAsConsume = true;
		}
	}
}
