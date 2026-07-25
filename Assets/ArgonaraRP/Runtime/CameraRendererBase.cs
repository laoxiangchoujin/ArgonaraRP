using UnityEngine;
using UnityEngine.Rendering;

public abstract class CameraRendererBase
{
	public abstract void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
		bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
		ShadowSettings shadowSettings, PostFXSettings postFXSettings, int colorLUTResolution);

	public abstract void Dispose();
	
	
}
