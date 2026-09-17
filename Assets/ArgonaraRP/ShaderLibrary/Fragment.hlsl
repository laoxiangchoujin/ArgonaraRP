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

//=========================== 全屏 pass 的公共工具（延迟光照 / 屏幕空间 PCSS 都用）===========================

///深度图（原始depth）→ 世界坐标：全屏 pass 重建位置/法线都走它（翻转口径同 DeferredLightPassFragment）
float3 ScreenSpaceWorldPosFromDepth (float2 uv, float rawDepth)
{
	float4 posClip = float4(uv * 2 - 1, rawDepth, 1);
	#if UNITY_UV_STARTS_AT_TOP
		posClip.y = -posClip.y;
	#endif
	float4 posWS = mul(UNITY_MATRIX_I_VP, posClip);
	return posWS.xyz / posWS.w;
}

///阴影偏移用的**几何面法线**（不含法线图扰动）。
///全屏 pass 里没有"顶点内插法线"，这里用**深度邻居**把它重构出来，而不是用 ddx/ddy：
///导数是"象限级"的，物体轮廓那圈像素的 quad 里混进了背景/远处物体的世界坐标 ⇒ 导数本身就是错的
///（PCSS 那条路栽过这个："边缘斜率爆炸 ⇒ 阴影整块消失"）。
///做法：±1 格的四个邻居里，**每个屏幕轴各挑"视深度离中心更近"的那一侧**（天空/背景的深度最远，
///      永远不会被选中）⇒ 轮廓处被选中的点必然还在这条面上 ⇒ 叉乘出来就是这条面的准确法线，
///      所以既不需要容差、也不需要额外的回退判据。
///input：positionWS/viewDepth 来自 GBuffer 重建；shadingNormal = 着色法线（前向 Lit 的法线图与 GBuffer2 都行，
///      只用来统一朝向、以及"差太远就判定不可信"的兜底）；uv = 屏幕 UV。
float3 ScreenSpaceGeometricNormal (float3 positionWS, float viewDepth, float3 shadingNormal, float2 uv)
{
	float2 texel = _CameraBufferSize.xy;//(1/宽, 1/高)
	//⚠️ 轴向偏移必须拆开：直接 ±texel 是"对角线"，四个邻居会变成斜向 + 只有 y 向，边缘应对就不对称了
	float2 dx = float2(texel.x, 0.0), dy = float2(0.0, texel.y);
	float2 uvLeft = uv - dx, uvRight = uv + dx;
	float2 uvDown = uv - dy, uvUp = uv + dy;
	float rawLeft = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uvLeft);
	float rawRight = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uvRight);
	float rawDown = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uvDown);
	float rawUp = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uvUp);

	//每个轴挑"离中心最近"的那一侧（天空/背景的深度最远，永远不会被选中）
	float3 posX = (abs(LinearEyeDepth(rawRight, _ZBufferParams) - viewDepth) <
	               abs(LinearEyeDepth(rawLeft, _ZBufferParams) - viewDepth))
		? ScreenSpaceWorldPosFromDepth(uvRight, rawRight)
		: ScreenSpaceWorldPosFromDepth(uvLeft, rawLeft);
	float3 posY = (abs(LinearEyeDepth(rawUp, _ZBufferParams) - viewDepth) <
	               abs(LinearEyeDepth(rawDown, _ZBufferParams) - viewDepth))
		? ScreenSpaceWorldPosFromDepth(uvUp, rawUp)
		: ScreenSpaceWorldPosFromDepth(uvDown, rawDown);

	float3 geoNormal = cross(posX - positionWS, posY - positionWS);
	if (!(dot(geoNormal, geoNormal) > 1e-24))//退化（两个同面点和中心重合了）⇒ 用着色法线
	{
		return shadingNormal;
	}
	geoNormal = normalize(geoNormal);
	geoNormal *= sign(dot(geoNormal, shadingNormal));//统一朝向（叉乘的手性/朝向可能相反）
	//与着色法线差太远（法线贴图也扰不到 75° 以上）⇒ 几何法线不可信，退回着色法线
	return geoNormal;
}

#endif
