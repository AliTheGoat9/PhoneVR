// Head orientation math. Header-only and free of OpenVR / OS dependencies so it can be unit tested.
//
// Frames
//   Android world (ENU):  X east, Y north, Z up.
//   Android device:       X right, Y up (portrait), Z out of the screen.
//   OpenVR / head:        X right, Y up, -Z forward (gaze).
//
// The phone sits in the headset in landscape with the screen facing the eyes, so the device +Z axis
// points from the screen towards the user's face, which is *backwards* in head space (head +Z).
//   Landscape (ROTATION_90, phone top edge on the user's left):  head X = -dev Y, head Y = +dev X, head Z = +dev Z
//   Reverse landscape (ROTATION_270, top edge on the right):     head X = +dev Y, head Y = -dev X, head Z = +dev Z
#pragma once
#include <cmath>

namespace phonevr
{
struct Mat3
{
	double m[ 3 ][ 3 ];
};
struct Vec3
{
	double x, y, z;
};
struct Quat
{
	double x, y, z, w;
};

inline Mat3 Identity()
{
	return { { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } };
}

inline Mat3 Mul( const Mat3 &a, const Mat3 &b )
{
	Mat3 r{};
	for ( int i = 0; i < 3; i++ )
		for ( int j = 0; j < 3; j++ )
			r.m[ i ][ j ] = a.m[ i ][ 0 ] * b.m[ 0 ][ j ] + a.m[ i ][ 1 ] * b.m[ 1 ][ j ] + a.m[ i ][ 2 ] * b.m[ 2 ][ j ];
	return r;
}

inline Vec3 Mul( const Mat3 &a, const Vec3 &v )
{
	return { a.m[ 0 ][ 0 ] * v.x + a.m[ 0 ][ 1 ] * v.y + a.m[ 0 ][ 2 ] * v.z,
			 a.m[ 1 ][ 0 ] * v.x + a.m[ 1 ][ 1 ] * v.y + a.m[ 1 ][ 2 ] * v.z,
			 a.m[ 2 ][ 0 ] * v.x + a.m[ 2 ][ 1 ] * v.y + a.m[ 2 ][ 2 ] * v.z };
}

inline Mat3 Transpose( const Mat3 &a )
{
	Mat3 r{};
	for ( int i = 0; i < 3; i++ )
		for ( int j = 0; j < 3; j++ )
			r.m[ i ][ j ] = a.m[ j ][ i ];
	return r;
}

inline Quat Normalize( Quat q )
{
	double n = std::sqrt( q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w );
	if ( n < 1e-9 )
		return { 0, 0, 0, 1 };
	return { q.x / n, q.y / n, q.z / n, q.w / n };
}

inline Mat3 ToMat3( Quat q )
{
	q = Normalize( q );
	const double x = q.x, y = q.y, z = q.z, w = q.w;
	Mat3 r{};
	r.m[ 0 ][ 0 ] = 1 - 2 * ( y * y + z * z );
	r.m[ 0 ][ 1 ] = 2 * ( x * y - z * w );
	r.m[ 0 ][ 2 ] = 2 * ( x * z + y * w );
	r.m[ 1 ][ 0 ] = 2 * ( x * y + z * w );
	r.m[ 1 ][ 1 ] = 1 - 2 * ( x * x + z * z );
	r.m[ 1 ][ 2 ] = 2 * ( y * z - x * w );
	r.m[ 2 ][ 0 ] = 2 * ( x * z - y * w );
	r.m[ 2 ][ 1 ] = 2 * ( y * z + x * w );
	r.m[ 2 ][ 2 ] = 1 - 2 * ( x * x + y * y );
	return r;
}

inline Quat ToQuat( const Mat3 &a )
{
	const double tr = a.m[ 0 ][ 0 ] + a.m[ 1 ][ 1 ] + a.m[ 2 ][ 2 ];
	Quat q{};
	if ( tr > 0 )
	{
		double s = std::sqrt( tr + 1.0 ) * 2; // s = 4w
		q.w = 0.25 * s;
		q.x = ( a.m[ 2 ][ 1 ] - a.m[ 1 ][ 2 ] ) / s;
		q.y = ( a.m[ 0 ][ 2 ] - a.m[ 2 ][ 0 ] ) / s;
		q.z = ( a.m[ 1 ][ 0 ] - a.m[ 0 ][ 1 ] ) / s;
	}
	else if ( a.m[ 0 ][ 0 ] > a.m[ 1 ][ 1 ] && a.m[ 0 ][ 0 ] > a.m[ 2 ][ 2 ] )
	{
		double s = std::sqrt( 1.0 + a.m[ 0 ][ 0 ] - a.m[ 1 ][ 1 ] - a.m[ 2 ][ 2 ] ) * 2; // s = 4x
		q.w = ( a.m[ 2 ][ 1 ] - a.m[ 1 ][ 2 ] ) / s;
		q.x = 0.25 * s;
		q.y = ( a.m[ 0 ][ 1 ] + a.m[ 1 ][ 0 ] ) / s;
		q.z = ( a.m[ 0 ][ 2 ] + a.m[ 2 ][ 0 ] ) / s;
	}
	else if ( a.m[ 1 ][ 1 ] > a.m[ 2 ][ 2 ] )
	{
		double s = std::sqrt( 1.0 + a.m[ 1 ][ 1 ] - a.m[ 0 ][ 0 ] - a.m[ 2 ][ 2 ] ) * 2; // s = 4y
		q.w = ( a.m[ 0 ][ 2 ] - a.m[ 2 ][ 0 ] ) / s;
		q.x = ( a.m[ 0 ][ 1 ] + a.m[ 1 ][ 0 ] ) / s;
		q.y = 0.25 * s;
		q.z = ( a.m[ 1 ][ 2 ] + a.m[ 2 ][ 1 ] ) / s;
	}
	else
	{
		double s = std::sqrt( 1.0 + a.m[ 2 ][ 2 ] - a.m[ 0 ][ 0 ] - a.m[ 1 ][ 1 ] ) * 2; // s = 4z
		q.w = ( a.m[ 1 ][ 0 ] - a.m[ 0 ][ 1 ] ) / s;
		q.x = ( a.m[ 0 ][ 2 ] + a.m[ 2 ][ 0 ] ) / s;
		q.y = ( a.m[ 1 ][ 2 ] + a.m[ 2 ][ 1 ] ) / s;
		q.z = 0.25 * s;
	}
	return Normalize( q );
}

inline Mat3 RotY( double a )
{
	const double c = std::cos( a ), s = std::sin( a );
	return { { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } };
}

// Android ENU world -> OpenVR world:  (x, y, z) -> (x, z, -y)
inline Mat3 AndroidWorldToVr()
{
	return { { { 1, 0, 0 }, { 0, 0, 1 }, { 0, -1, 0 } } };
}

// Columns are the head axes expressed in device coordinates.
inline Mat3 HeadAxesInDevice( bool landscapeRight )
{
	if ( landscapeRight )
		return { { { 0, -1, 0 }, { 1, 0, 0 }, { 0, 0, 1 } } }; // X = +devY, Y = -devX, Z = +devZ
	return { { { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 } } };     // X = -devY, Y = +devX, Z = +devZ
}

// Converts the phone's rotation-vector quaternion (device -> ENU world) to the head orientation in VR world space.
inline Mat3 HeadToVrWorld( Quat deviceToWorld, bool landscapeRight )
{
	return Mul( Mul( AndroidWorldToVr(), ToMat3( deviceToWorld ) ), HeadAxesInDevice( landscapeRight ) );
}

// Yaw (rotation about +Y, counter-clockwise seen from above) of the head's forward direction.
// Returns false if the user is looking almost straight up/down and yaw is ill-defined.
inline bool ForwardYaw( const Mat3 &head, double *yaw )
{
	const Vec3 f = Mul( head, Vec3{ 0, 0, -1 } );
	if ( std::sqrt( f.x * f.x + f.z * f.z ) < 0.25 )
		return false;
	*yaw = std::atan2( -f.x, -f.z );
	return true;
}

// Tracks the yaw offset applied on recenter and turns raw sensor data into VR-space head poses.
class HeadPoseTracker
{
public:
	// Raw head orientation (before recentering).
	Mat3 Raw( Quat deviceToWorld, bool landscapeRight ) const { return HeadToVrWorld( deviceToWorld, landscapeRight ); }

	// Make the current facing direction "forward" (-Z in VR space).
	bool Recenter( const Mat3 &rawHead )
	{
		double yaw;
		if ( !ForwardYaw( rawHead, &yaw ) )
			return false;
		yawOffset_ = -yaw;
		return true;
	}

	Mat3 Apply( const Mat3 &rawHead ) const { return Mul( RotY( yawOffset_ ), rawHead ); }
	double YawOffset() const { return yawOffset_; }

private:
	double yawOffset_ = 0.0;
};

// Angular velocity in VR world space from the phone gyro (device frame).
inline Vec3 GyroToWorld( const Mat3 &recenteredHead, const double gyroDev[ 3 ], bool landscapeRight )
{
	const Mat3 m = HeadAxesInDevice( landscapeRight );
	const Vec3 head = Mul( Transpose( m ), Vec3{ gyroDev[ 0 ], gyroDev[ 1 ], gyroDev[ 2 ] } ); // device -> head axes
	return Mul( recenteredHead, head );                                                          // head -> VR world
}
} // namespace phonevr
