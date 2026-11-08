// Standalone checks for the head-orientation math. Build:  g++ -std=c++17 -I../src test_pose.cpp -o test_pose
#include "pose_math.h"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

using namespace phonevr;

static int g_fail = 0;
#define CHECK( cond, ... )                         \
	do                                             \
	{                                              \
		if ( !( cond ) )                           \
		{                                          \
			g_fail++;                              \
			printf( "FAIL %s:%d  ", __FILE__, __LINE__ ); \
			printf( __VA_ARGS__ );                 \
			printf( "\n" );                        \
		}                                          \
	} while ( 0 )

static bool Near( double a, double b, double eps = 1e-6 ) { return std::fabs( a - b ) < eps; }

static bool MatNear( const Mat3 &a, const Mat3 &b, double eps = 1e-6 )
{
	for ( int i = 0; i < 3; i++ )
		for ( int j = 0; j < 3; j++ )
			if ( !Near( a.m[ i ][ j ], b.m[ i ][ j ], eps ) )
				return false;
	return true;
}

// Rotations in Android ENU world: about up (Z) and about east (X).
static Mat3 RotUpA( double a )
{
	const double c = std::cos( a ), s = std::sin( a );
	return { { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } } };
}
static Mat3 RotEastA( double a )
{
	const double c = std::cos( a ), s = std::sin( a );
	return { { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } };
}
static Mat3 RotXvr( double a )
{
	const double c = std::cos( a ), s = std::sin( a );
	return { { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } };
}

// Device -> world for a user facing north, head upright, phone in landscape (top edge on the user's left):
// dev X -> up, dev Y -> west, dev Z -> south (towards the user's face).
static Mat3 FacingNorthLandscapeLeft()
{
	return { { { 0, -1, 0 }, { 0, 0, -1 }, { 1, 0, 0 } } };
}
// Same head pose with the phone turned 180 degrees in-plane (top edge on the user's right):
// dev X -> down, dev Y -> east, dev Z -> south.
static Mat3 FacingNorthLandscapeRight()
{
	return { { { 0, 1, 0 }, { 0, 0, -1 }, { -1, 0, 0 } } };
}

static Quat Q( const Mat3 &m ) { return ToQuat( m ); }

int main()
{
	// quaternion <-> matrix round trip
	{
		Mat3 r = Mul( RotUpA( 0.7 ), RotEastA( -0.4 ) );
		CHECK( MatNear( ToMat3( ToQuat( r ) ), r ), "quat round trip" );
		for ( double a : { 3.0, -3.0, 3.1 } ) // exercises the non-trace branches
		{
			Mat3 rr = Mul( RotEastA( a ), RotUpA( a * 0.5 ) );
			CHECK( MatNear( ToMat3( ToQuat( rr ) ), rr ), "quat round trip large angle %f", a );
		}
	}

	// 1. Facing north, upright -> identity in VR space (forward = -Z, right = +X, up = +Y)
	{
		Mat3 h = HeadToVrWorld( Q( FacingNorthLandscapeLeft() ), false );
		CHECK( MatNear( h, Identity() ), "north/landscape-left should be identity" );
		Mat3 h2 = HeadToVrWorld( Q( FacingNorthLandscapeRight() ), true );
		CHECK( MatNear( h2, Identity() ), "north/landscape-right should be identity" );
	}

	// 2. Turn head 30 deg to the left (counter-clockwise from above) -> +30 deg about +Y in VR
	{
		const double a = 30.0 * M_PI / 180.0;
		Mat3 dev = Mul( RotUpA( a ), FacingNorthLandscapeLeft() );
		Mat3 h = HeadToVrWorld( Q( dev ), false );
		CHECK( MatNear( h, RotY( a ) ), "yaw left 30" );
		Vec3 f = Mul( h, Vec3{ 0, 0, -1 } );
		CHECK( f.x < 0 && f.z < 0, "turning left should point forward towards -X (west) and -Z (north): %f %f", f.x, f.z );

		Mat3 devR = Mul( RotUpA( a ), FacingNorthLandscapeRight() );
		CHECK( MatNear( HeadToVrWorld( Q( devR ), true ), RotY( a ) ), "yaw left 30 (landscape right)" );
	}

	// 3. Look up 20 deg -> +20 deg about +X in VR (forward vector gets +Y)
	{
		const double a = 20.0 * M_PI / 180.0;
		Mat3 dev = Mul( RotEastA( a ), FacingNorthLandscapeLeft() );
		Mat3 h = HeadToVrWorld( Q( dev ), false );
		CHECK( MatNear( h, RotXvr( a ) ), "pitch up 20" );
		Vec3 f = Mul( h, Vec3{ 0, 0, -1 } );
		CHECK( f.y > 0.3, "looking up should raise the forward vector" );
	}

	// 4. Recenter: user faces west (90 deg left), recenters, then turns 10 deg more
	{
		HeadPoseTracker t;
		Mat3 dev90 = Mul( RotUpA( M_PI / 2 ), FacingNorthLandscapeLeft() );
		Mat3 raw = t.Raw( Q( dev90 ), false );
		CHECK( t.Recenter( raw ), "recenter should succeed" );
		CHECK( MatNear( t.Apply( raw ), Identity() ), "after recenter the pose is identity" );

		Mat3 dev100 = Mul( RotUpA( M_PI / 2 + 10.0 * M_PI / 180.0 ), FacingNorthLandscapeLeft() );
		Mat3 out = t.Apply( t.Raw( Q( dev100 ), false ) );
		CHECK( MatNear( out, RotY( 10.0 * M_PI / 180.0 ) ), "10 deg left of the recentered forward" );
	}

	// 5. Recenter must not change pitch or roll
	{
		HeadPoseTracker t;
		const double yaw = 50.0 * M_PI / 180.0, pitch = 25.0 * M_PI / 180.0;
		Mat3 dev = Mul( RotUpA( yaw ), Mul( RotEastA( pitch ), FacingNorthLandscapeLeft() ) );
		Mat3 raw = t.Raw( Q( dev ), false );
		CHECK( t.Recenter( raw ), "recenter with pitch" );
		Vec3 f = Mul( t.Apply( raw ), Vec3{ 0, 0, -1 } );
		CHECK( Near( f.x, 0, 1e-6 ), "forward x after recenter %f", f.x );
		CHECK( Near( f.y, std::sin( pitch ), 1e-6 ), "pitch preserved %f", f.y );
	}

	// 6. Looking straight up: yaw ill-defined, recenter refuses
	{
		HeadPoseTracker t;
		Mat3 dev = Mul( RotEastA( M_PI / 2 ), FacingNorthLandscapeLeft() );
		CHECK( !t.Recenter( t.Raw( Q( dev ), false ) ), "no recenter when looking straight up" );
	}

	// 7. Gyro: turning left at 1 rad/s about head-up. Landscape-left: head up = +devX.
	{
		const double g[ 3 ] = { 1, 0, 0 };
		Vec3 w = GyroToWorld( Identity(), g, false );
		CHECK( Near( w.x, 0 ) && Near( w.y, 1 ) && Near( w.z, 0 ), "gyro landscape-left: %f %f %f", w.x, w.y, w.z );
		const double g2[ 3 ] = { -1, 0, 0 };
		Vec3 w2 = GyroToWorld( Identity(), g2, true );
		CHECK( Near( w2.y, 1 ), "gyro landscape-right: head up = -devX" );
	}

	printf( g_fail ? "%d FAILED\n" : "all pose math checks passed\n", g_fail );
	return g_fail ? 1 : 0;
}
