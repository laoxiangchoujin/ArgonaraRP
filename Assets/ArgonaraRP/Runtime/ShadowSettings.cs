using UnityEngine;

[System.Serializable]
public class ShadowSettings
{
    //主相机周围多少米范围内的物体才需要考虑投射阴影，
    //这个值增大，会让shadowmap在一定分辨率内包含更多东西，让单个物体阴影占像素变少（反之会变大，但也可能忽略应该有阴影的稍远的物体）
    [Min(0.001f)]public float maxDistance = 100f;
    
    [Range(0.001f, 1f)]public float distanceFade = 0.1f;//衰减后阴影强度公式是(1-depth/maxDistance)/f，此参数表示从最大距离开始，向相机走1分之多少，阴影强度从0变成1

    //阴影滤波档位：定向光与其他光**共用**这一套（shader 关键字只有 _SHADOW_PCF3/5/7 一组），所以提到这里统一控制。
    //它同时决定：① 采样核大小 ② 各级联/其他光的法线偏移量(避免自阴影)。
    public FilterMode filter = FilterMode.PCF7x7;

    public enum TextureSize
    {
        _64 = 64, _256 = 256, _512 = 512, _1024 = 1024, _2048 = 2048, _4096 = 4096, _8192 = 8192
    }

    //定向光阴影
    ///将来我希望把它改成叫DirectionalCascadeSetting，暂时隐忍
    [System.Serializable]
    public struct Directional
    {
        //public TextureSize atlasSize;//图集大小，说是图集，是因为会用一张大贴图包含多个shadowmap
        public TextureSize tileSize;//图集里的一个tile的大小，这里用tile大小，和灯数量，级联数量，共同决定整个shadowmap的大小，而不是整个预设固定的图片大小

        //在某个距离上，阴影贴图纹素恰好能映射到一个单独的屏幕像素，此时阴影分辨率在理论上最佳。
        //级联阴影贴图，思想是投射阴影的物体被渲染多次，因此每个光源在图集中都有多个图块，称为级联。第一个级联只覆盖靠近相机的小区域，而后续的级联逐渐放大，以相同数量的纹素覆盖越来越大的区域。
        [Range(1, 8)] public int cascadeCount;//为什么教程说“Unity的阴影代码支持每个定向光最多四个级联阴影贴图”？做成更多也没事吧
        //[Range(0f, 1f)] public float cascadeRatio1, cascadeRatio2, cascadeRatio3;//各层级联覆盖阴影距离的的比例逐级增加，ratio4默认是1，最大的级联要覆盖整个范围

        public float[] cascadeRatios;//前 cascadeCount-1 个是“各级联的内部分界比例”，最后一级固定延伸到1(整个阴影距离)。
        //改级联数时数组不必跟着改：只取前 cascadeCount-1 个，多余的忽略。长度 >= cascadeCount-1 即可。
        //假如要8个级联，那么需要7个表示占比的数字，就用数组了

        [Range(0.001f, 1f)] public float cascadeFade;//级联阴影最大层与外边的交界处，也要有渐隐

        public enum CascadeBlendMode//在级联间采样混合会让采样数多一倍，因此，，，
        {
            Hard,
            Soft,
            Dither
        }
        public CascadeBlendMode cascadeBlend;

        //PCSS（仅对主定向光生效）单独成一组，Inspector 里可以折叠
        [System.Serializable]
        public struct Pcss
        {
            public bool enabled;//总开关
            //Blocker Search 的搜索半径：不用填世界长度，而是"取最细级联(cascade0)的这么多个纹素"作为世界半径。
            //这样它会自动随分辨率、级联比例、相机设置变化；每个级联另外保证至少能搜到自己 1 个纹素。
            //(≤0 视为默认 20)
            [Range(4, 64)] public int searchTexels;
            //半影上限：同样表达成"最细级联(cascade0)的这么多个纹素"，但它在 shader 里被换算成一个**恒定世界长度**。
            //关键：半影的世界大小必须与级联无关，级联相关的量只能出现在"换算"里；否则同一块几何在粗细级联的
            //世界半影会差上百倍(1 纹素的世界尺寸逐级联约翻倍)，看起来就是"一头糊一头清"。≤0 视为默认 20
            [Range(2, 256)] public int filterTexels;
            [Range(8, 32)] public int blockerSamples;
            [Range(8, 32)] public int samples;
            [Range(0.75f, 1.5f)] public float penumbraPow;//半影半径的幂次修正，1=原始相似三角形结果
            [Range(0f, 0.3f)] public float padding;//基础深度偏移(占光相机深度范围的比例)
            [Range(0f, 4f)] public float slopeBias;//深度偏移随斜率(掠射角)与核半径的强度，1=AKG式
            [Range(0f, 4f)] public float normalBias;//沿几何法线偏移着色点(单位:1.414×阴影纹素世界尺寸；填主光的Shadow Normal Bias即可与PCF对齐)
        }
        public Pcss pcss;
    }

    public Directional directional = new Directional
    {
        //atlasSize = TextureSize._1024,
        tileSize = TextureSize._64,

        cascadeCount = 8,
        cascadeRatios = new float[] { 0.05f, 0.1f, 0.2f, 0.35f, 0.5f, 0.65f, 0.8f },//7个内部分界，8级时最后一级=0.8~1.0
        
        
        cascadeFade = 0.1f,
        cascadeBlend = Directional.CascadeBlendMode.Hard
    };

    //阴影滤波档位（由上面的 ShadowSettings.filter 统一控制，定向光与其他光共用）
    public enum FilterMode
    {
        PCF2x2, PCF3x3, PCF5x5, PCF7x7
    }

    //其他光源的阴影
    [System.Serializable]
    public struct Other
    {
        public TextureSize atlasSize;
    }

    public Other other = new Other
    {
        atlasSize = TextureSize._1024
    };
}
