#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

constant float euler = 2.71828182846;
constant int octaveCount = 4;

float scaled(float edge0, float edge1, float value) {
    return clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
}

float fixedSpring(float time, float damping) {
    float spring = mix(
        1.0 - exp(-euler * 2.0 * time) * cos((1.0 - damping) * 115.0 * time),
        1.0,
        clamp(time, 0.0, 1.0)
    );
    return spring * (1.0 - time) + time;
}

float3 blendLinearBurn(float3 base, float3 blend, float opacity) {
    return max(base + blend - float3(1.0), float3(0.0)) * opacity + base * (1.0 - opacity);
}

float4 permute(float4 value) {
    return fmod((value * 34.0 + 1.0) * value, 289.0);
}

float4 taylorInverseSqrt(float4 value) {
    return 1.79284291400159 - 0.85373472095314 * value;
}

float3 fade3(float3 value) {
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

float random2D(float2 value) {
    return fract(sin(dot(value, float2(12.9898, 4.1414))) * 43758.5453);
}

float valueNoise(float2 point) {
    float2 integerPoint = floor(point);
    float2 fraction = fract(point);
    float2 blend = fraction * fraction * (3.0 - 2.0 * fraction);
    float result = mix(
        mix(random2D(integerPoint), random2D(integerPoint + float2(1.0, 0.0)), blend.x),
        mix(random2D(integerPoint + float2(0.0, 1.0)), random2D(integerPoint + float2(1.0, 1.0)), blend.x),
        blend.y
    );
    return result * result;
}

float fractionalBrownianMotion(float2 point) {
    float value = 0.0;
    float amplitude = 0.5;
    float2 shift = float2(100.0);
    float angle = 0.5;
    float2x2 rotation = float2x2(cos(angle), sin(angle), -sin(angle), cos(angle));

    for (int index = 0; index < octaveCount; ++index) {
        value += amplitude * valueNoise(point);
        point = rotation * point * 2.0 + shift;
        amplitude *= 0.5;
    }
    return value;
}

float classicNoise(float3 point) {
    float3 pi0 = floor(point);
    float3 pi1 = pi0 + float3(1.0);
    pi0 = fmod(pi0, 289.0);
    pi1 = fmod(pi1, 289.0);
    float3 pf0 = fract(point);
    float3 pf1 = pf0 - float3(1.0);

    float4 ix = float4(pi0.x, pi1.x, pi0.x, pi1.x);
    float4 iy = float4(pi0.y, pi0.y, pi1.y, pi1.y);
    float4 iz0 = float4(pi0.z);
    float4 iz1 = float4(pi1.z);
    float4 ixy = permute(permute(ix) + iy);
    float4 ixy0 = permute(ixy + iz0);
    float4 ixy1 = permute(ixy + iz1);

    float4 gx0 = ixy0 / 7.0;
    float4 gy0 = fract(floor(gx0) / 7.0) - 0.5;
    gx0 = fract(gx0);
    float4 gz0 = float4(0.5) - abs(gx0) - abs(gy0);
    float4 sz0 = step(gz0, float4(0.0));
    gx0 -= sz0 * (step(float4(0.0), gx0) - 0.5);
    gy0 -= sz0 * (step(float4(0.0), gy0) - 0.5);

    float4 gx1 = ixy1 / 7.0;
    float4 gy1 = fract(floor(gx1) / 7.0) - 0.5;
    gx1 = fract(gx1);
    float4 gz1 = float4(0.5) - abs(gx1) - abs(gy1);
    float4 sz1 = step(gz1, float4(0.0));
    gx1 -= sz1 * (step(float4(0.0), gx1) - 0.5);
    gy1 -= sz1 * (step(float4(0.0), gy1) - 0.5);

    float3 g000 = float3(gx0.x, gy0.x, gz0.x);
    float3 g100 = float3(gx0.y, gy0.y, gz0.y);
    float3 g010 = float3(gx0.z, gy0.z, gz0.z);
    float3 g110 = float3(gx0.w, gy0.w, gz0.w);
    float3 g001 = float3(gx1.x, gy1.x, gz1.x);
    float3 g101 = float3(gx1.y, gy1.y, gz1.y);
    float3 g011 = float3(gx1.z, gy1.z, gz1.z);
    float3 g111 = float3(gx1.w, gy1.w, gz1.w);

    float4 norm0 = taylorInverseSqrt(float4(
        dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110)
    ));
    g000 *= norm0.x;
    g010 *= norm0.y;
    g100 *= norm0.z;
    g110 *= norm0.w;

    float4 norm1 = taylorInverseSqrt(float4(
        dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111)
    ));
    g001 *= norm1.x;
    g011 *= norm1.y;
    g101 *= norm1.z;
    g111 *= norm1.w;

    float n000 = dot(g000, pf0);
    float n100 = dot(g100, float3(pf1.x, pf0.y, pf0.z));
    float n010 = dot(g010, float3(pf0.x, pf1.y, pf0.z));
    float n110 = dot(g110, float3(pf1.x, pf1.y, pf0.z));
    float n001 = dot(g001, float3(pf0.x, pf0.y, pf1.z));
    float n101 = dot(g101, float3(pf1.x, pf0.y, pf1.z));
    float n011 = dot(g011, float3(pf0.x, pf1.y, pf1.z));
    float n111 = dot(g111, pf1);

    float3 fadeValue = fade3(pf0);
    float4 nz = mix(float4(n000, n100, n010, n110), float4(n001, n101, n011, n111), fadeValue.z);
    float2 nyz = mix(nz.xy, nz.zw, fadeValue.y);
    return 2.2 * mix(nyz.x, nyz.y, fadeValue.x);
}

float noiseTextureChannel(SwiftUI::Layer layer, float2 uv, float2 viewport, int channel) {
    float2 samplePosition = clamp(uv, float2(0.0), float2(1.0)) * viewport;
    half4 sampleColor = layer.sample(samplePosition);
    return channel == 0 ? float(sampleColor.r) : float(sampleColor.g);
}

[[ stitchable ]] half4 cloudWaveOrb(
    float2 position,
    SwiftUI::Layer noiseLayer,
    float2 viewport,
    float animationTime,
    float stateTime,
    float audioLevel,
    float voiceState,
    float patternSeed,
    float3 mainColor,
    float3 lowColor,
    float3 midColor,
    float3 highColor
) {
    float2 outputUV = position / viewport;
    float2 centered = outputUV - 0.5;
    centered.y *= viewport.y / viewport.x;

    float entryAnimation = fixedSpring(scaled(0.0, 2.0, stateTime), 0.92);
    float response = clamp(audioLevel, 0.0, 1.0);
    float energy = voiceState == 1.0 ? response : (voiceState == 3.0 ? max(response, 0.35) : 0.0);
    float2 seedOffset = float2(patternSeed * 0.754877666, patternSeed * 0.569840296);

    float baseRadius = 0.37 + energy * 0.018;
    float radius = baseRadius * mix(0.9, 1.0, entryAnimation);
    float scaleFactor = 1.0 / (2.0 * radius);
    float2 uv = centered * scaleFactor + 0.5;
    uv.y = 1.0 - uv.y;

    float noiseScale = 1.25;
    float windSpeed = 0.12 + energy * 0.04;
    float warpPower = 0.35 + energy * 0.04;
    float waterColorNoiseScale = 18.0;
    float waterColorNoiseStrength = 0.02;
    float textureNoiseScale = 1.0;
    float textureNoiseStrength = 0.15;
    float verticalOffset = 0.09;
    float waveSpread = 1.0;
    float layer1Amplitude = 1.5;
    float layer2Amplitude = 1.4;
    float layer3Amplitude = 1.3;
    float fbmStrength = 1.2;
    float fbmPowerDamping = 0.55;
    float blurRadius = 1.5;
    float stateSpeed = voiceState == 2.0 ? 0.72 : 1.0;
    float time = animationTime * stateSpeed * 0.85;

    // Several deliberately mismatched, low-frequency cycles make the large-scale
    // flow evolve over minutes instead of exposing one recognizable loop.
    float2 macroDrift = float2(
        sin(time * 0.037 + patternSeed * 1.71) * 0.055 +
            sin(time * 0.0131 + patternSeed * 0.43) * 0.025,
        cos(time * 0.029 + patternSeed * 1.19) * 0.045 +
            sin(time * 0.0113 + patternSeed * 0.67) * 0.025
    );
    float evolvingDirection =
        sin(time * 0.017 + patternSeed * 0.31) * 0.10 +
        sin(time * 0.0067 + patternSeed * 0.79) * 0.06;
    float2x2 directionRotation = float2x2(
        cos(evolvingDirection), sin(evolvingDirection),
        -sin(evolvingDirection), cos(evolvingDirection)
    );
    uv = directionRotation * (uv - 0.5) + 0.5 + macroDrift;

    float noiseX = classicNoise(float3(uv + float2(0.0, 74.8572) + seedOffset, time * 0.3 + patternSeed * 0.17));
    float noiseY = classicNoise(float3(uv + float2(203.91282, 10.0) + seedOffset.yx, time * 0.271 + patternSeed * 0.11));
    uv += float2(noiseX * 2.0, noiseY) * warpPower;

    float noiseA = classicNoise(float3(uv * waterColorNoiseScale + float2(344.91282, 0.0) + seedOffset, time * 0.3));
    noiseA += classicNoise(float3(uv * waterColorNoiseScale * 2.2 + float2(723.937, 0.0) + seedOffset.yx, time * 0.417)) * 0.5;
    uv += noiseA * waterColorNoiseStrength;
    uv.y -= verticalOffset;

    float2 textureUV = uv * textureNoiseScale;
    float textureSampleR0 = noiseTextureChannel(noiseLayer, textureUV, viewport, 0);
    float textureSampleG0 = noiseTextureChannel(noiseLayer, float2(textureUV.x, 1.0 - textureUV.y), viewport, 1);
    float textureBlend0 = clamp(
        0.5 + sin(time * 0.113 + patternSeed) * 0.28 +
            sin(time * 0.047 + patternSeed * 1.37) * 0.18,
        0.0,
        1.0
    );
    float textureNoiseDisp0 = mix(textureSampleR0 - 0.5, textureSampleG0 - 0.5, textureBlend0) * textureNoiseStrength;

    textureUV += float2(63.861, 368.937);
    float textureSampleR1 = noiseTextureChannel(noiseLayer, textureUV, viewport, 0);
    float textureSampleG1 = noiseTextureChannel(noiseLayer, float2(textureUV.x, 1.0 - textureUV.y), viewport, 1);
    float textureBlend1 = clamp(
        0.5 + sin(time * 0.097 + patternSeed * 0.73) * 0.25 +
            cos(time * 0.031 + patternSeed * 1.91) * 0.21,
        0.0,
        1.0
    );
    float textureNoiseDisp1 = mix(textureSampleR1 - 0.5, textureSampleG1 - 0.5, textureBlend1) * textureNoiseStrength;

    textureUV += float2(272.861, 829.937);
    textureUV += float2(180.302, 819.871);
    float textureSampleR3 = noiseTextureChannel(noiseLayer, textureUV, viewport, 0);
    float textureSampleG3 = noiseTextureChannel(noiseLayer, float2(textureUV.x, 1.0 - textureUV.y), viewport, 1);
    float textureBlend3 = clamp(
        0.5 + cos(time * 0.127 + patternSeed * 1.13) * 0.27 +
            sin(time * 0.041 + patternSeed * 0.57) * 0.19,
        0.0,
        1.0
    );
    float textureNoiseDisp3 = mix(textureSampleR3 - 0.5, textureSampleG3 - 0.5, textureBlend3) * textureNoiseStrength;
    uv += textureNoiseDisp0;

    float2 fbmPoint = (uv + seedOffset * 0.07) * noiseScale;
    float2 q;
    q.x = fractionalBrownianMotion(fbmPoint * 0.5 + float2(windSpeed * time, 0.0));
    q.y = fractionalBrownianMotion(
        fbmPoint * 0.5 + float2(5.2, -2.7) + float2(-0.031, windSpeed * 0.91) * time
    );
    float2 r;
    r.x = fractionalBrownianMotion(fbmPoint + q + float2(0.3, 9.2) + 0.15 * time);
    r.y = fractionalBrownianMotion(fbmPoint + q + float2(8.3, 0.8) + 0.126 * time);
    float f = fractionalBrownianMotion(fbmPoint + r - q);
    float fullFbm = (f + 0.6 * f * f + 0.7 * f + 0.5) * 0.5;
    fullFbm = pow(fullFbm, fbmPowerDamping) * fbmStrength;

    float firstFrequency = 2.0 * (1.0 + sin(time * 0.019 + patternSeed * 0.83) * 0.06);
    float secondFrequency = 4.0 * (1.0 + sin(time * 0.0143 + patternSeed * 1.27) * 0.08);
    float thirdFrequency = 6.0 * (1.0 + cos(time * 0.0107 + patternSeed * 0.61) * 0.07);

    float2 firstUV = uv + float2((fullFbm - 0.5) * 1.2) + float2(0.0, 0.025) + textureNoiseDisp0;
    float2 firstTravel = float2(time * 0.041, time * 0.5) + macroDrift * 0.4 + seedOffset;
    float firstNoise = valueNoise(firstUV * firstFrequency + firstTravel) * 2.0 * layer1Amplitude;
    float firstWave = smoothstep(firstNoise - 1.2 * blurRadius, firstNoise + 1.2 * blurRadius, (firstUV.y - 0.5 * waveSpread) * 5.0 + 0.5);

    float2 secondUV = uv + float2((fullFbm - 0.5) * 0.85) + float2(0.0, 0.025) + textureNoiseDisp1;
    float2 secondTravel = float2(293.0 - time * 0.071, time * 0.93) + macroDrift.yx * 0.7 + seedOffset.yx;
    float secondNoise = valueNoise(secondUV * secondFrequency + secondTravel) * 2.0 * layer2Amplitude;
    float secondWave = smoothstep(secondNoise - 0.9 * blurRadius, secondNoise + 0.9 * blurRadius, (secondUV.y - 0.6 * waveSpread) * 5.0 + 0.5);

    float2 thirdUV = uv + float2((fullFbm - 0.5) * 1.1) + textureNoiseDisp3;
    float2 thirdTravel = float2(153.0 + time * 0.089, time * 1.17) - macroDrift * 0.5 + seedOffset * 1.31;
    float thirdNoise = valueNoise(thirdUV * thirdFrequency + thirdTravel) * 2.0 * layer3Amplitude;
    float thirdWave = smoothstep(thirdNoise - 0.7 * blurRadius, thirdNoise + 0.7 * blurRadius, (thirdUV.y - 0.9 * waveSpread) * 6.0 + 0.5);

    firstWave = pow(firstWave, 0.8);
    secondWave = pow(secondWave, 0.9);

    float3 color = blendLinearBurn(mainColor, lowColor, 1.0 - firstWave);
    color = blendLinearBurn(color, mix(mainColor, midColor, 1.0 - secondWave), firstWave);
    color = mix(color, mix(mainColor, highColor, 1.0 - thirdWave), firstWave * secondWave);

    float distanceToOrb = length(centered) - radius;
    float alpha = 1.0 - smoothstep(0.0, 0.0075, distanceToOrb);
    return half4(half3(color * alpha), half(alpha));
}
