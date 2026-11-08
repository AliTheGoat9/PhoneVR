// Wire format between the phone app and the SteamVR driver (UDP, little-endian, tightly packed).
//
//   phone -> PC  UDP :udp_port (5555)           PosePacket    52 bytes, sent at sensor rate
//   PC -> phone  UDP :phone_config_port (5001)  ConfigPacket  28 bytes, sent on connect and once per second
//   PC -> phone  RTP :5000                      H.265 video from ffmpeg (see pc/start_stream.ps1)
//
// The Android app mirrors these layouts in android/.../Protocol.kt - keep both in sync.
// driver/tests/test_link.py checks the byte layout independently with Python's struct module.
#pragma once
#include <cstdint>

namespace phonevr
{
constexpr uint32_t kPoseMagic = 0x50525650;   // bytes "PVRP"
constexpr uint32_t kConfigMagic = 0x43525650; // bytes "PVRC"
constexpr uint16_t kProtocolVersion = 1;

// PosePacket::flags
constexpr uint16_t kFlagLandscapeRight = 1 << 0; // display rotation is ROTATION_270 (phone top edge on the user's right)
constexpr uint16_t kFlagRecenter = 1 << 1;       // held while the user asks to recenter; driver acts on the rising edge

#pragma pack( push, 1 )
struct PosePacket
{
	uint32_t magic;        // kPoseMagic
	uint16_t version;      // kProtocolVersion
	uint16_t flags;
	uint32_t seq;
	uint64_t sensorTimeNs; // SensorEvent.timestamp
	float q[ 4 ];          // rotation-vector quaternion x, y, z, w: device -> Android ENU world (GAME_ROTATION_VECTOR)
	float gyro[ 3 ];       // rad/s, device frame (TYPE_GYROSCOPE)
	float ipdMm;           // interpupillary distance the user dialed in on the phone
};

struct ConfigPacket
{
	uint32_t magic;        // kConfigMagic
	uint16_t version;      // kProtocolVersion
	uint16_t reserved;
	float tanHalfX;        // half-FOV tangents of the (symmetric) per-eye projection
	float tanHalfY;
	uint16_t eyeWidth;     // per-eye viewport in the captured window, pixels
	uint16_t eyeHeight;
	float displayHz;
	float appliedIpdMm;    // IPD the driver is currently using
};
#pragma pack( pop )

static_assert( sizeof( PosePacket ) == 52, "PosePacket layout" );
static_assert( sizeof( ConfigPacket ) == 28, "ConfigPacket layout" );
} // namespace phonevr
