using UnityEngine;

///应该是整个后处理所有堆栈的，基座
[CreateAssetMenu(menuName = "Rendering/Custom PostFXSettings")]
public class PostFXSettings : ScriptableObject
{
   [SerializeField] 
   private Shader shader = default;
   
   //渲染时会临时生成材质，这里按需创建，设为隐藏，不保存到项目中，，，因为是按需创建，so材质不能序列化
   [System.NonSerialized] 
   private Material material;

   public Material Material
   {
      get
      {
         if (material == null && shader != null)//这好像没考虑shader是空咋办
         {
            material = new Material(shader);
            material.hideFlags = HideFlags.HideAndDontSave;
         }
         return material;
      }
   }
   
   
   //以下为bloom相关代码


   [System.Serializable]
   public struct BloomSettings
   {
      [Header("金字塔")]
      [Tooltip("最大迭代次数，决定金字塔层数")] [Range(0f, 16f)] public int maxIterations;

      [Tooltip("降采样下限(px)，低于此尺寸停止")] [Min(1f)] public int downscaleLimit;

      [Tooltip("启用双三次上采样(高质量光晕)")] public bool bicubicUpsampling;

      
      [Header("阈值与强度")]
      [Tooltip("亮度阈值，低于此值不产生Bloom")] [Min(0f)] public float threshold;

      [Tooltip("阈值过渡宽度，0=硬裁切，越大越柔和")] [Range(0f, 1f)] public float thresholdKnee; //knee是把阈值硬裁切变成软过渡，knee是过渡的宽度，从threshold~threshold+knee之间渐变变化
      
      [Tooltip("Bloom强度，最终叠加的倍率")] [Min(0f)] public float intensity;
   }

   [SerializeField] BloomSettings bloom = default;//inspector里实际看到的是这一个，而非下边的public
   public BloomSettings Bloom => bloom;//这个public，提供一个只读属性，让其他代码不能像普通public一样改
}
