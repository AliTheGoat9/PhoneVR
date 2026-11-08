// Loopback test for UdpLink. Run together with test_link.py (see that file).
#include "udp_link.h"

#include <chrono>
#include <cstdio>

using namespace phonevr;

int main()
{
	UdpLink link;
	int got = 0;
	std::string err;
	bool ok = link.Start(
		15555,
		[ & ]( const PosePacket &p ) {
			got++;
			printf( "pose seq=%u flags=%u q=(%.3f %.3f %.3f %.3f) gyro=(%.2f %.2f %.2f) ipd=%.1f t=%llu\n", p.seq, p.flags, p.q[ 0 ], p.q[ 1 ], p.q[ 2 ], p.q[ 3 ], p.gyro[ 0 ], p.gyro[ 1 ], p.gyro[ 2 ], p.ipdMm,
					(unsigned long long)p.sensorTimeNs );
			fflush( stdout );
		},
		[]( const std::string &ip ) {
			printf( "new peer %s\n", ip.c_str() );
			fflush( stdout );
		},
		&err );
	if ( !ok )
	{
		printf( "start failed: %s\n", err.c_str() );
		return 2;
	}
	printf( "ready\n" );
	fflush( stdout );

	// wait for packets, then answer with a config packet
	for ( int i = 0; i < 40 && got < 3; i++ )
		std::this_thread::sleep_for( std::chrono::milliseconds( 50 ) );

	ConfigPacket cfg{};
	cfg.magic = kConfigMagic;
	cfg.version = kProtocolVersion;
	cfg.tanHalfX = 1.19f;
	cfg.tanHalfY = 1.07f;
	cfg.eyeWidth = 1496;
	cfg.eyeHeight = 1344;
	cfg.displayHz = 120.f;
	cfg.appliedIpdMm = 63.5f;
	link.SendConfig( cfg, 15001 );
	std::this_thread::sleep_for( std::chrono::milliseconds( 200 ) );
	link.Stop();
	printf( "done received=%d\n", got );
	return got == 3 ? 0 : 1;
}
