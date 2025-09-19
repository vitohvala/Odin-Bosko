cbuffer constants : register(b0)
{
    float2 screensize;
    float2 atlassize;
}

struct vout {
    float4 position : SV_POSITION;
    float2 uv : UV;
    float4 color : COLOR;
};

struct vin {
    uint vertex_id : SV_VERTEXID;
    uint inst_id : SV_INSTANCEID;
};

struct IDK {
    float2 pos;
    float2 size;
};

struct Sprite {
    IDK sprite;
    IDK atlas;
    float3 color;
};

//copied from https://gist.github.com/d7samurai/8f91f0343c411286373161202c199b5c
StructuredBuffer<Sprite> spritebuffer : register(t0);
Texture2D<float4>        atlastexture : register(t1);

SamplerState             pointsampler : register(s0);

vout vs_main(vin input) {
    vout output;

    Sprite spr = spritebuffer[input.inst_id];
    IDK sprite = spr.sprite;
    IDK atlas = spr.atlas;
    float3 color = spr.color;

    //sprite.size.y = -sprite.size.y;

    float2 vertices[6]  = {
        sprite.pos,
        sprite.pos + float2(sprite.size.x, 0.0),
        sprite.pos + float2(0.0, sprite.size.y),
        sprite.pos + float2(0.0, sprite.size.y),
        sprite.pos + float2(sprite.size.x, 0.0),
        sprite.pos + sprite.size,
    };
    float2 pos = (vertices[input.vertex_id] / screensize) * 2 - 1;
    pos.y = -pos.y;

//    float4 texpos;

    float2 uvMin = atlas.pos / atlassize;
    float2 uvMax = (atlas.pos + atlas.size) / atlassize;

    float2 uv[6] = {
        float2(uvMin.x, uvMin.y),  // top left
        float2(uvMax.x, uvMin.y),  // top right
        float2(uvMin.x, uvMax.y),  // bottom left
        float2(uvMin.x, uvMax.y),  // bottom left
        float2(uvMax.x, uvMin.y),  // top right
        float2(uvMax.x, uvMax.y)   // bottom right
    };

    output.position = float4(pos.x, pos.y, 0, 1);
    // output.color = float4(colors[vertex_ID], 1.0f);
    output.uv = uv[input.vertex_id];
    output.color = float4(color, 1.0f);
    return output;
}


float4 ps_main(vout input) : SV_TARGET {
    float4 color = atlastexture.Sample(pointsampler, input.uv);
    if (color.a == 0) discard;
    return color * input.color;
}