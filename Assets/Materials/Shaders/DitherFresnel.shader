Shader "Custom/DitherFresnel"
{
    Properties
    {
        [MainTexture] _BaseMap ("Base Map", 2D) = "white" {}
        [MainColor] _BaseColor ("Base Color", Color) = (1,1,1,1)

        _Fade ("Overall Opacity", Range(0,1)) = 1
        _DitherScale ("Dither Pixel Size", Range(1,8)) = 1

        _FresnelPower ("Fresnel Power (edge tightness)", Range(0.1,8)) = 2
        _FresnelStrength ("Fresnel Strength", Range(0,1)) = 1
        [Toggle] _InvertFresnel ("Invert (fade the center instead)", Float) = 0

        _LightInfluence ("Light Influence (0 = unlit)", Range(0,1)) = 1
    }

    SubShader
    {
        Tags { "RenderType"="TransparentCutout" "Queue"="AlphaTest" "RenderPipeline"="UniversalPipeline" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4 _BaseColor;
            half _Fade;
            half _DitherScale;
            half _FresnelPower;
            half _FresnelStrength;
            half _InvertFresnel;
            half _LightInfluence;
        CBUFFER_END

        // 4x4 Bayer matrix, normalized to (0,1)
        float Bayer4x4(float2 pixel)
        {
            static const float m[16] = {
                 0,  8,  2, 10,
                12,  4, 14,  6,
                 3, 11,  1,  9,
                15,  7, 13,  5
            };
            uint2 p = uint2(pixel) % 4;
            return (m[p.y * 4 + p.x] + 0.5) / 16.0;
        }

        // 0 at the center of the object (facing camera), 1 at the silhouette edge
        float FresnelTerm(float3 positionWS, float3 normalWS)
        {
            float3 v = normalize(_WorldSpaceCameraPos - positionWS);
            float ndv = saturate(dot(normalize(normalWS), v));
            float f = pow(1.0 - ndv, _FresnelPower);
            return _InvertFresnel > 0.5 ? 1.0 - f : f;
        }

        // Opacity drops toward the edges (or the center, if inverted)
        float FresnelOpacity(float3 positionWS, float3 normalWS)
        {
            float f = FresnelTerm(positionWS, normalWS);
            return _Fade * (1.0 - f * _FresnelStrength);
        }

        void DitherClip(float4 positionCS, float opacity)
        {
            float2 pixel = floor(positionCS.xy / _DitherScale);
            clip(opacity - Bayer4x4(pixel));
        }
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }
            Cull Back
            ZWrite On

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; float2 uv : TEXCOORD0; };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
                float2 uv         : TEXCOORD2;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs vp = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = vp.positionCS;
                OUT.positionWS = vp.positionWS;
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half4 tex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv) * _BaseColor;
                DitherClip(IN.positionCS, FresnelOpacity(IN.positionWS, IN.normalWS) * tex.a);

                float4 shadowCoord = TransformWorldToShadowCoord(IN.positionWS);
                Light l = GetMainLight(shadowCoord);
                half3 n = normalize(IN.normalWS);
                half3 diffuse = l.color * l.shadowAttenuation * saturate(dot(n, l.direction));
                half3 ambient = SampleSH(n);
                half3 lighting = lerp(half3(1, 1, 1), diffuse + ambient, _LightInfluence);
                return half4(tex.rgb * lighting, 1);
            }
            ENDHLSL
        }

        // Shadows use the overall opacity only (fresnel depends on the camera, not the light)
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode"="ShadowCaster" }
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; float2 uv : TEXCOORD0; };
            struct Varyings { float4 positionCS : SV_POSITION; float2 uv : TEXCOORD0; };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                float3 posWS = TransformObjectToWorld(IN.positionOS.xyz);
                float3 nWS = TransformObjectToWorldNormal(IN.normalOS);
            #if defined(_CASTING_PUNCTUAL_LIGHT_SHADOW)
                float3 lightDir = normalize(_LightPosition - posWS);
            #else
                float3 lightDir = _LightDirection;
            #endif
                OUT.positionCS = TransformWorldToHClip(ApplyShadowBias(posWS, nWS, lightDir));
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half a = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).a * _BaseColor.a;
                DitherClip(IN.positionCS, _Fade * a);
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode"="DepthOnly" }
            ColorMask 0
            ZWrite On

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; float2 uv : TEXCOORD0; };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
                float2 uv         : TEXCOORD2;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.positionCS = TransformWorldToHClip(OUT.positionWS);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half a = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).a * _BaseColor.a;
                DitherClip(IN.positionCS, FresnelOpacity(IN.positionWS, IN.normalWS) * a);
                return 0;
            }
            ENDHLSL
        }
    }
}
