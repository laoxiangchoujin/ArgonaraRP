#ifndef FRAGMENT_INCLUDED
#define FRAGMENT_INCLUDED

TEXTURE2D(_CameraColorTexture);
//按纹理命名的那套采样器：状态取自纹理自己（颜色快照带 mip 时建的是 Trilinear）⇒ LOD 采样会在相邻两级 mip
//之间插值，不会出现"取整到最近一级"的突变（sampler_linear_clamp 这类静态命名采样器的 mip 过滤是"点"的）。
//SSR 采反射色用它（那边的 lod 是粗糙度算出来的，是小数）。
SAMPLER(sampler_CameraColorTexture);
//既然是片元需要深度那么在此采样深度图
TEXTURE2D(_CameraDepthTexture);

float4 _CameraBufferSize;

struct Fragment {
	float2 positionSS;//屏幕空间像素坐标
	float2 screenUV;//?
	float depth;//片元的线性实际深度
	float bufferDepth;//深度图的线性实际深度
};

Fragment GetFragment (float4 positionSS) {
	Fragment f;
	f.positionSS = positionSS.xy;
	f.screenUV = f.positionSS * _CameraBufferSize.xy;//屏幕坐标/像素宽高 = 01的屏幕UV	//替代了_ScreenParams
	f.depth = IsOrthographicCamera() ? OrthographicDepthBufferToLinear(positionSS.z) : positionSS.w;//这个w，就是透视投影下的实际深度值，，，如果用z就是用非线性值反算回线性绕一大圈
	f.bufferDepth = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, sampler_point_clamp, f.screenUV, 0);
	f.bufferDepth = IsOrthographicCamera() ? OrthographicDepthBufferToLinear(f.bufferDepth) : LinearEyeDepth(f.bufferDepth, _ZBufferParams);
	return f;
}

float4 GetBufferColor (Fragment fragment, float2 uvOffset = float2(0.0, 0.0)) {
	float2 uv = fragment.screenUV + uvOffset;
	return SAMPLE_TEXTURE2D_LOD(_CameraColorTexture, sampler_linear_clamp, uv, 0);
}

#endif
