using UnityEditor;
using UnityEngine;

static class RepaintAlwaysInSceneView
{
    const string Key = "Argonara.RepaintAlwaysInSceneView";

    const string Path = "Tools/Argonara/强制Scene视图每帧重绘";

    [MenuItem(Path)]
    static void Toggle() => EditorPrefs.SetBool(Key, !EditorPrefs.GetBool(Key, false));

    //validate：菜单打开时跑，用 SetChecked 显示当前状态
    [MenuItem(Path, true)]
    static bool ToggleValidate()
    {
        Menu.SetChecked(Path, EditorPrefs.GetBool(Key, false));
        return true;
    }

    [InitializeOnLoadMethod]
    static void Hook()
    {
        EditorApplication.update += () =>
        {
            if (!Application.isPlaying && EditorPrefs.GetBool(Key, false))
                SceneView.RepaintAll();
        };
    }
}
