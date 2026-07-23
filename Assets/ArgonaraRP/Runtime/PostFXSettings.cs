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
         if (material == null && shader != null)
         {
            material = new Material(shader);
            material.hideFlags = HideFlags.HideAndDontSave;
         }
         return material;
      }
   }
   
   //-----------------bloom-------------------//
   
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

      [Tooltip("是否消除HDR点状闪光")]public bool fadeFireflies;
      
      
      public enum Mode {Additive, Scattering}//经典的叠加式 Bloom 和能量守恒散射 Bloom

      [Header("散射模式")]
      public Mode mode;

      [Range(0.05f, 0.95f)] public float scatter;//scatter模式是将两层blur结果做lerp，那么不能用0或1的值，那没有意义

      public bool ignoreRenderScale;//bloom依赖于分辨率，和渲染缩放有关。
   }

   [SerializeField] BloomSettings bloom = new BloomSettings
   {
      scatter = 0.7f,    //URP、HDRP的默认值
      downscaleLimit = 1 //int默认为0，会炸，手动设1保护
   }; //inspector里实际看到的是这一个，而非下边的public
   public BloomSettings Bloom => bloom;//这个public，提供一个只读属性，让其他代码不能像普通public一样改


   //-----------------Color Adjustments-------------------//

   [System.Serializable]
   public struct ColorAdjustmentsSettings
   {
      public float postExposure;

      [Range(-100f, 100f)] public float contrast;

      [ColorUsage(false, true)] public Color colorFilter;

      [Range(-180f, 180f)] public float hueShift;

      [Range(-100f, 100f)] public float saturation;
   }

   [SerializeField] ColorAdjustmentsSettings colorAdjustments = new ColorAdjustmentsSettings
   {
      colorFilter = Color.white//调色的默认值全0，且这个是白色，就不会更改图像
   };

   public ColorAdjustmentsSettings ColorAdjustments => colorAdjustments;



   //-----------------White Balance-------------------//

   [System.Serializable]
   public struct WhiteBalanceSettings
   {

      [Range(-100f, 100f)] public float temperature;//色温，低温变蓝，高温变橙黄     模拟黑体辐射从冷到热   通常用较小值
      [Range(-100f, 100f)] public float tint;//补偿不希望的色彩平衡，低值变绿，高值变品红    真实光源不会完美落在黑体曲线上，如荧光灯偏绿，它补正这个色调偏移
   }

   [SerializeField] WhiteBalanceSettings whiteBalance = default;

   public WhiteBalanceSettings WhiteBalance => whiteBalance;


   //-----------------Split Toning-------------------//
   //色调分离，针对亮度上的暗部和亮部，分别用Adobe的柔光混合模式染色
   [System.Serializable]
   public struct SplitToningSettings
   {

      [ColorUsage(false)]
      public Color shadows, highlights;//阴影和高光分别调色，默认灰色即无影响

      [Range(-100f, 100f)]
      public float balance;//控制阴影/高光的过渡点，>0则更多像素视为高光
   }

   [SerializeField]
   SplitToningSettings splitToning = new SplitToningSettings
   {
      shadows = Color.gray,
      highlights = Color.gray
   };

   public SplitToningSettings SplitToning => splitToning;


   //-----------------Channel Mixer-------------------//

   [System.Serializable]
   public struct ChannelMixerSettings
   {

      public Vector3 red, green, blue;//3×3矩阵，行=输出色，列=RGB输入，默认单位矩阵即无修改
   }

   [SerializeField]
   ChannelMixerSettings channelMixer = new ChannelMixerSettings
   {
      red = Vector3.right,   // (1,0,0) 输出红只取输入红
      green = Vector3.up,    // (0,1,0)
      blue = Vector3.forward // (0,0,1)
   };

   public ChannelMixerSettings ChannelMixer => channelMixer;


   //-----------------Shadows Midtones Highlights-------------------//
   //中文叫啥？，，，对亮度上的暗部、灰部、亮部，分别做乘法混合，和色调混合类似，但是控制会更精准
   [System.Serializable]
   public struct ShadowsMidtonesHighlightsSettings
   {

      [ColorUsage(false, true)]//因为是乘法混合，要想亮部更亮，就需要hdr颜色
      public Color shadows, midtones, highlights;//三段独立染色，默认白色=无影响，HDR可>1提亮

      [Range(0f, 2f)]
      public float shadowsStart, shadowsEnd, highlightsStart, highLightsEnd;//阴影/高光的过渡起止范围
   }

   [SerializeField]
   ShadowsMidtonesHighlightsSettings
      shadowsMidtonesHighlights = new ShadowsMidtonesHighlightsSettings {
         shadows = Color.white,
         midtones = Color.white,
         highlights = Color.white,
         shadowsEnd = 0.3f,
         highlightsStart = 0.55f,
         highLightsEnd = 1f
      };

   public ShadowsMidtonesHighlightsSettings ShadowsMidtonesHighlights =>
      shadowsMidtonesHighlights;
   
   
   

   //-----------------Tone Mapping-------------------//

   [System.Serializable]
   public struct ToneMappingSettings
   {

      public enum Mode
      {
         None,
         ACES,
         Neutral,
         Reinhard
      }

      public Mode mode;
   }

   [SerializeField] ToneMappingSettings toneMapping = default;

   public ToneMappingSettings ToneMapping => toneMapping;
}
