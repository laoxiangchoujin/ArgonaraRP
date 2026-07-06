using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

//编辑器分部类，用来实现，多个scene窗口可以分别启用或关闭后处理
//"切换天空盒、雾和各自其他效果"里的post processing
public partial class PostFXStack
{
	partial void ApplySceneViewState();
	
	#if UNITY_EDITOR
	partial void ApplySceneViewState()
	{
		if (camera.cameraType == CameraType.SceneView &&
		    !SceneView.currentDrawingSceneView.sceneViewState.showImageEffects)//是场景相机，且场景窗口的显示设置里，没开启后处理
		{
			settings = null;//在本帧设置stack的setting为null，那么enabled就是false；没在动pipelineAsset的setting
		}
	}
	#endif
}
