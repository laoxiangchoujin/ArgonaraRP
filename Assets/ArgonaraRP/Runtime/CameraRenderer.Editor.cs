using UnityEditor;
using UnityEngine;
using UnityEngine.Profiling;
using UnityEngine.Rendering;

partial class CameraRenderer
{
    //CameraRenderer无论是否在editor，都在调用它，而我们希望它只在editor出现，
    //这里我们用partial声明分部函数，当编译器找不到partial函数的实现时，会自动删掉所有此函数的调用
    partial void DrawUnsupportedShaders();

    //partial void DrawGizmos();
    ///说是gizmos，在后处理前后渲染是有区别的，，，所以分成两个
    partial void DrawGizmosBeforeFX();

    partial void DrawGizmosAfterFX();

    partial void PrepareForSceneWindow();

    partial void PrepareBuffer();

#if UNITY_EDITOR
    private static ShaderTagId[] legacyShaderTagIDs =
    {
        new ShaderTagId("Always"),
        new ShaderTagId("ForwardBase"),
        new ShaderTagId("PrepassBase"),
        new ShaderTagId("Vertex"),
        new ShaderTagId("VertexLMRGBM"),
        new ShaderTagId("VertexLM"),
    }; //unity默认的shader，本管线不支持，但要像是错误shader画洋红色那样，也绘制出来

    private static Material errorMaterial;

    ///绘制本SRP不支持的unity默认shader
    partial void DrawUnsupportedShaders()
    {
        if (errorMaterial == null)
        {
            errorMaterial = new Material(Shader.Find("Hidden/InternalErrorShader"));
        }

        var drawingSettings = new DrawingSettings(legacyShaderTagIDs[0], new SortingSettings(camera))
        {
            overrideMaterial = errorMaterial //unity的默认shader不支持，用这个InternalErrorShader渲染
        };
        for (int i = 1; i < legacyShaderTagIDs.Length; i++)
        {
            drawingSettings.SetShaderPassName(i, legacyShaderTagIDs[i]); //没看懂这是干嘛
        }

        var filteringSettings = FilteringSettings.defaultValue;
        context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
    }
    
    ///绘制editor gizmos，说是分两部分，图像效果的前后两个
    // partial void DrawGizmos()
    // {
    //     if (Handles.ShouldRenderGizmos())
    //     {
    //         context.DrawGizmos(camera, GizmoSubset.PreImageEffects);//这里的imageEffects指的是什么？render feature吗？
    //         context.DrawGizmos(camera, GizmoSubset.PostImageEffects);
    //     }
    // }

    partial void DrawGizmosBeforeFX()
    {
        if (Handles.ShouldRenderGizmos())
        {
            context.DrawGizmos(camera, GizmoSubset.PreImageEffects);
            //context.DrawGizmos(camera, GizmoSubset.PostImageEffects);
        }
    }

    partial void DrawGizmosAfterFX()
    {
        if (Handles.ShouldRenderGizmos())
        {
            context.DrawGizmos(camera, GizmoSubset.PostImageEffects);
        }
    }
    
    ///绘制scene view里的UI，显式地将 UI 物体添加到世界几何体中
    partial void PrepareForSceneWindow()
    {
        if (camera.cameraType == CameraType.SceneView)
        {
            ScriptableRenderContext.EmitWorldGeometryForSceneView(camera);
        }
    }

    private string SampleName { get; set; }
    
    ///让每个相机的buffer有自己的名字
    partial void PrepareBuffer()
    {
        Profiler.BeginSample("Editor Only");//这个Profiler Sample，只是表明，我们只在editor模式分配内存
        buffer.name = SampleName = camera.name;//editor模式下方便在profiler里看每个相机的buffer名称
        Profiler.EndSample();
    }
#else
    const string SampleName = bufferName;//非editor模式下，比如打包了，自然用不上看profiler了，另外，获取两个camera.name会造成约50b的gc alloc，如此能避免
    
#endif
}