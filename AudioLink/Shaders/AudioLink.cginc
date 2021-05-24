// Map of where features in AudioLink are.
#define ALPASS_DFT              int2(0,4)
#define ALPASS_WAVEFORM         int2(0,6)
#define ALPASS_AUDIOLINK        int2(0,0)
#define ALPASS_AUDIOLINKHISTORY int2(1,0) 
#define ALPASS_GENERALVU        int2(0,22)

#define ALPASS_GENERALVU_INSTANCE_TIME   int2(2,22)
#define ALPASS_GENERALVU_LOCAL_TIME      int2(3,22)

#define ALPASS_CCINTERNAL       int2(12,22)
#define ALPASS_CCSTRIP          int2(0,24)
#define ALPASS_CCLIGHTS         int2(0,25)
#define ALPASS_AUTOCORRELATOR   int2(0,27)

// Some basic constants to use (Note, these should be compatible with
// future version of AudioLink, but may change.
#define CCMAXNOTES 10
#define SAMPHIST 3069 //Internal use for algos, do not change.
#define SAMPLEDATA24 2046
#define EXPBINS 24
#define EXPOCT 10
#define ETOTALBINS ((EXPBINS)*(EXPOCT))
#define AUDIOLINK_WIDTH  128
#define _SamplesPerSecond 48000
#define _RootNote 0

// We use glsl_mod for most calculations because it behaves better
// on negative numbers, and in some situations actually outperforms
// HLSL's modf().
#ifndef glsl_mod
#define glsl_mod(x,y) (((x)-(y)*floor((x)/(y)))) 
#endif

uniform float4               _AudioLinkTexture_TexelSize; 

#ifdef SHADER_TARGET_SURFACE_ANALYSIS
#define AUDIOLINK_STANDARD_INDEXING
#endif

// Mechanism to index into texture.
#ifdef AUDIOLINK_STANDARD_INDEXING
    sampler2D _AudioLinkTexture;
    #define AudioLinkData(xycoord) tex2Dlod( _AudioLinkTexture, float4( uint2(xycoord) * _AudioLinkTexture_TexelSize.xy, 0, 0 ) )
#else
    uniform Texture2D<float4>   _AudioLinkTexture;
    #define AudioLinkData(xycoord) _AudioLinkTexture[uint2(xycoord)]
#endif

// Convenient mechanism to read from the AudioLink texture that handles reading off the end of one line and onto the next above it.
float4 AudioLinkDataMultiline( uint2 xycoord) { return AudioLinkData(uint2(xycoord.x % AUDIOLINK_WIDTH, xycoord.y + xycoord.x/AUDIOLINK_WIDTH)); }

// Mechanism to sample between two adjacent pixels and lerp between them, like "linear" supesampling
float4 AudioLinkLerp(float2 xy) { return lerp( AudioLinkData(xy), AudioLinkData(xy+int2(1,0)), frac( xy.x ) ); }

// Same as AudioLinkLerp but properly handles multiline reading.
float4 AudioLinkLerpMultiline(float2 xy) { return lerp( AudioLinkDataMultiline(xy), AudioLinkDataMultiline(xy+float2(1,0)), frac( xy.x ) ); }

// Decompress a RGBA FP16 into a really big number, this is used in some sections of the info block.
#define DecodeLongFloat( vALValue )  (vALValue.r + vALValue.g*1024 + vALValue.b * 1048576 + vALValue.a * 1073741824 )


// Extra utility functions for time.
uint ALDecodeDataAsUInt( uint2 sample )
{
    half4 rpx = AudioLinkData( sample );
    return DecodeLongFloat( rpx );
}


//Note: This will truncate time to every 134,217.728 seconds (~1.5 days of an instance being up) to prevent floating point aliasing.
// if your code will alias sooner, you will need to use a different function.
float ALDecodeDataAsFloat( uint2 sample )
{
    return (ALDecodeDataAsUInt( sample ) & 0x7ffffff) / 1000.;
}



// ColorChord features

#ifndef CCclamp
#define CCclamp(x,y,z) clamp( x, y, z )
#endif

float CCRemap(float t, float a, float b, float u, float v) {return ( (t-a) / (b-a) ) * (v-u) + u;}

float3 CCHSVtoRGB(float3 HSV)
{
    float3 RGB = 0;
    float C = HSV.z * HSV.y;
    float H = HSV.x * 6;
    float X = C * (1 - abs(fmod(H, 2) - 1));
    if (HSV.y != 0)
    {
        float I = floor(H);
        if (I == 0) { RGB = float3(C, X, 0); }
        else if (I == 1) { RGB = float3(X, C, 0); }
        else if (I == 2) { RGB = float3(0, C, X); }
        else if (I == 3) { RGB = float3(0, X, C); }
        else if (I == 4) { RGB = float3(X, 0, C); }
        else { RGB = float3(C, 0, X); }
    }
    float M = HSV.z - C;
    return RGB + M;
}

float3 CCtoRGB( float bin, float intensity, int RootNote )
{
    float note = bin / EXPBINS;

    float hue = 0.0;
    note *= 12.0;
    note = glsl_mod( 4.-note + RootNote, 12.0 );
    {
        if( note < 4.0 )
        {
            //Needs to be YELLOW->RED
            hue = (note) / 24.0;
        }
        else if( note < 8.0 )
        {
            //            [4]  [8]
            //Needs to be RED->BLUE
            hue = ( note-2.0 ) / 12.0;
        }
        else
        {
            //             [8] [12]
            //Needs to be BLUE->YELLOW
            hue = ( note - 4.0 ) / 8.0;
        }
    }
    float val = intensity-.1;
    return CCHSVtoRGB( float3( fmod(hue,1.0), 1.0, CCclamp( val, 0.0, 1.0 ) ) );
}


// Used for debugging
float PrintNumberOnLine( float number, uint fixeddiv, uint digit, float2 mxy, int offset, bool leadzero )
{
    uint selnum;
    if( number < 0 && digit == 0 )
    {
        selnum = 11;
    }
    else
    {
        number = abs( number );

        if( digit == fixeddiv )
        {
            selnum = 10;
        }
        else
        {
            int dmfd = (int)digit - (int)fixeddiv;
            if( dmfd > 0 )
            {
                //fractional part.
                float l10 = pow( 10., dmfd );
                selnum = ((uint)( number * l10 )) % 10;
            }
            else
            {
                float l10 = pow( 10., (float)(dmfd + 1) );
                selnum = ((uint)( number * l10 ));

                //Disable leading 0's?
                if( !leadzero && dmfd != -1 && selnum == 0 && dmfd < 0.5 ) 
                    selnum = 12;
                else
                    selnum %= (uint)10;
            }
        }
    }

    const static uint BitmapNumberFont[13] = {
        15379168,  // '0' 1110 1010 1010 1010 1110 0000
        4473920,   // '1' 0100 0100 0100 0100 0100 0000
        14870752,  // '2' 1110 0010 1110 1000 1110 0000
        14836448,  // '3' 1110 0010 0110 0010 1110 0000
        11199008,  // '4' 1010 1010 1110 0010 0010 0000
        15262432,  // '5' 1110 1000 1110 0010 1110 0000
        15264480,  // '6' 1110 1000 1110 1010 1110 0000
        14836800,  // '7' 1110 0010 0110 0100 0100 0000
        15395552,  // '8' 1110 1010 1110 1010 1110 0000
        15393376,  // '9' 1110 1010 1110 0010 0110 0000
        64,        // '.' 0000 0000 0000 0000 0100 0000
        57344,     // '-' 0000 0000 1110 0000 0000 0000
        0,         // ' '
    };
    
    uint bitmap = BitmapNumberFont[selnum];
    if( 0 )
    {
        // Ugly, line-drawing
        int2 lumx = mxy;
        return ((bitmap >> (lumx.x+lumx.y*4)) & 1)?1.0:0.0;
    }
    else
    {
        // Smooth style drawing.
        int2 lumx = mxy;
        int index = lumx.x + lumx.y * 4;
        int4 tolerp = int4(
            ((bitmap >> (index + 0))),
            ((bitmap >> (index + 1))),
            ((bitmap >> (index + 4))),
            ((bitmap >> (index + 5))) ) & 1;
        float2 shift = smoothstep( 0, 1, frac(mxy) );
        float ov = lerp( 
            lerp( tolerp.x, tolerp.y, shift.x ), 
            lerp( tolerp.z, tolerp.w, shift.x ), shift.y );
        return saturate( ov * 20 - 10 );
    }
}

