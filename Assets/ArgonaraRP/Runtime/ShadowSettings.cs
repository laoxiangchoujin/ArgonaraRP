using UnityEngine;

[System.Serializable]
public class ShadowSettings
{
    //主相机周围多少米范围内的物体才需要考虑投射阴影，
    //这个值增大，会让shadowmap在一定分辨率内包含更多东西，让单个物体阴影占像素变少（反之会变大，但也可能忽略应该有阴影的稍远的物体）
    [Min(0.001f)]public float maxDistance = 100f;
    
    [Range(0.001f, 1f)]public float distanceFade = 0.1f;//衰减后阴影强度公式是(1-depth/maxDistance)/f，此参数表示从最大距离开始，向相机走1分之多少，阴影强度从0变成1

    public enum TextureSize
    {
        _256 = 256, _512 = 512, _1024 = 1024, _2048 = 2048, _4096 = 4096, _8192 = 8192
    }

    ///将来我希望把它改成叫DirectionalCascadeSetting，暂时隐忍
    [System.Serializable]
    public struct Directional//定向光阴影
    {
        public TextureSize atlasSize;//图集大小，说是图集，是因为会用一张大贴图包含多个shadowmap

        public FilterMode filter;//滤波模式
        
        //在某个距离上，阴影贴图纹素恰好能映射到一个单独的屏幕像素，此时阴影分辨率在理论上最佳。
        //级联阴影贴图，思想是投射阴影的物体被渲染多次，因此每个光源在图集中都有多个图块，称为级联。第一个级联只覆盖靠近相机的小区域，而后续的级联逐渐放大，以相同数量的纹素覆盖越来越大的区域。
        [Range(1, 4)] public int cascadeCount;//为什么教程说“Unity的阴影代码支持每个定向光最多四个级联阴影贴图”？做成更多也没事吧
        [Range(0f, 1f)] public float cascadeRatio1, cascadeRatio2, cascadeRatio3;//各层级联覆盖阴影距离的的比例逐级增加，ratio4默认是1，最大的级联要覆盖整个范围

        public Vector3 CascadeRatios =>
            new Vector3(cascadeRatio1, cascadeRatio2, cascadeRatio3);

        [Range(0.001f, 1f)] public float cascadeFade;//级联阴影最大层与外边的交界处，也要有渐隐

        public enum CascadeBlendMode//在级联间采样混合会让采样数多一倍，因此，，，
        {
            Hard,
            Soft,
            Dither
        }
        public CascadeBlendMode cascadeBlend;
    }

    public Directional directional = new Directional
    {
        atlasSize = TextureSize._1024,
        filter = FilterMode.PCF2x2,
        
        cascadeCount = 4,
        cascadeRatio1 = 0.1f,
        cascadeRatio2 = 0.25f,
        cascadeRatio3 = 0.5f,
        
        cascadeFade = 0.1f,
        cascadeBlend = Directional.CascadeBlendMode.Hard
    };

    public enum FilterMode
    {
        PCF2x2, PCF3x3, PCF5x5, PCF7x7
    }

    [System.Serializable]
    public struct Other
    {
        public TextureSize atlasSize;
        public FilterMode filter;
    }

    public Other other = new Other
    {
        atlasSize = TextureSize._1024,
        filter = FilterMode.PCF2x2
    };
}
