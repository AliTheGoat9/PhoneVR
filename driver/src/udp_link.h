// Small cross-platform UDP helper: receives PosePackets from the phone on a background thread and can
// send ConfigPackets back to wherever the last pose packet came from.
#pragma once
#include "protocol.h"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET phonevr_sock_t;
static const phonevr_sock_t kInvalidSock = INVALID_SOCKET;
#define PHONEVR_CLOSESOCK closesocket
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int phonevr_sock_t;
static const phonevr_sock_t kInvalidSock = -1;
#define PHONEVR_CLOSESOCK close
#endif

namespace phonevr
{
class UdpLink
{
public:
	using PoseCallback = std::function< void( const PosePacket & ) >;
	using PeerCallback = std::function< void( const std::string &ip ) >;

	~UdpLink() { Stop(); }

	// Binds 0.0.0.0:port and starts the receive thread. Returns false (and fills *err) on failure.
	bool Start( uint16_t port, PoseCallback onPose, PeerCallback onNewPeer, std::string *err )
	{
		onPose_ = std::move( onPose );
		onNewPeer_ = std::move( onNewPeer );
#ifdef _WIN32
		WSADATA wsa;
		if ( WSAStartup( MAKEWORD( 2, 2 ), &wsa ) != 0 )
		{
			if ( err )
				*err = "WSAStartup failed";
			return false;
		}
		wsaStarted_ = true;
#endif
		sock_ = ::socket( AF_INET, SOCK_DGRAM, IPPROTO_UDP );
		if ( sock_ == kInvalidSock )
		{
			if ( err )
				*err = "socket() failed";
			return false;
		}

		int reuse = 1;
		setsockopt( sock_, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast< const char * >( &reuse ), sizeof( reuse ) );

		// Wake up every 100 ms so Stop() can join the thread.
#ifdef _WIN32
		DWORD tv = 100;
		setsockopt( sock_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast< const char * >( &tv ), sizeof( tv ) );
#else
		timeval tv{};
		tv.tv_sec = 0;
		tv.tv_usec = 100 * 1000;
		setsockopt( sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof( tv ) );
#endif

		sockaddr_in addr{};
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl( INADDR_ANY );
		addr.sin_port = htons( port );
		if ( ::bind( sock_, reinterpret_cast< sockaddr * >( &addr ), sizeof( addr ) ) != 0 )
		{
			if ( err )
				*err = "bind() failed on UDP port " + std::to_string( port ) + " (is another copy of SteamVR running?)";
			PHONEVR_CLOSESOCK( sock_ );
			sock_ = kInvalidSock;
			return false;
		}

		running_ = true;
		thread_ = std::thread( &UdpLink::Loop, this );
		return true;
	}

	void Stop()
	{
		if ( running_.exchange( false ) && thread_.joinable() )
			thread_.join();
		if ( sock_ != kInvalidSock )
		{
			PHONEVR_CLOSESOCK( sock_ );
			sock_ = kInvalidSock;
		}
#ifdef _WIN32
		if ( wsaStarted_ )
		{
			WSACleanup();
			wsaStarted_ = false;
		}
#endif
	}

	// Sends a config packet to the last phone we heard from. Safe to call from any thread.
	void SendConfig( const ConfigPacket &cfg, uint16_t phonePort )
	{
		if ( !havePeer_ || sock_ == kInvalidSock )
			return;
		sockaddr_in dst;
		{
			std::lock_guard< std::mutex > lock( peerMutex_ );
			dst = peer_;
		}
		dst.sin_port = htons( phonePort );
		sendto( sock_, reinterpret_cast< const char * >( &cfg ), sizeof( cfg ), 0, reinterpret_cast< sockaddr * >( &dst ), sizeof( dst ) );
	}

	uint64_t PacketsReceived() const { return received_; }

private:
	void Loop()
	{
		char buf[ 512 ];
		while ( running_ )
		{
			sockaddr_in from{};
#ifdef _WIN32
			int fromLen = sizeof( from );
#else
			socklen_t fromLen = sizeof( from );
#endif
			int n = static_cast< int >( recvfrom( sock_, buf, sizeof( buf ), 0, reinterpret_cast< sockaddr * >( &from ), &fromLen ) );
			if ( n < static_cast< int >( sizeof( PosePacket ) ) )
				continue; // timeout, error or runt packet

			PosePacket p;
			std::memcpy( &p, buf, sizeof( p ) );
			if ( p.magic != kPoseMagic || p.version != kProtocolVersion )
				continue;

			if ( !havePeer_ || from.sin_addr.s_addr != peer_.sin_addr.s_addr )
			{
				{
					std::lock_guard< std::mutex > lock( peerMutex_ );
					peer_ = from;
				}
				havePeer_ = true;
				if ( onNewPeer_ )
				{
					char ip[ 64 ] = { 0 };
					inet_ntop( AF_INET, &from.sin_addr, ip, sizeof( ip ) );
					onNewPeer_( ip );
				}
			}
			received_++;
			if ( onPose_ )
				onPose_( p );
		}
	}

	phonevr_sock_t sock_ = kInvalidSock;
	std::thread thread_;
	std::atomic< bool > running_{ false };
	std::atomic< bool > havePeer_{ false };
	std::atomic< uint64_t > received_{ 0 };
	std::mutex peerMutex_;
	sockaddr_in peer_{};
	PoseCallback onPose_;
	PeerCallback onNewPeer_;
#ifdef _WIN32
	bool wsaStarted_ = false;
#endif
};
} // namespace phonevr
