// PhoneVR - SteamVR driver for a phone used as a 3DoF headset.
//
//  * Presents an HMD whose "display" is a plain desktop window (extended mode).
//  An external encoder
//    (ffmpeg, see pc/start_stream.ps1) captures that window and streams it to
//    the phone.
//  * Lens distortion is NOT applied here (ComputeDistortion is identity); the
//  phone does it in a shader so
//    you can tune it live.
//  * Receives head orientation + IPD from the phone over UDP and feeds it to
//  SteamVR.
#if __has_include("openvr_driver.h")
#include "openvr_driver.h"
#else
#include "../third_party/openvr/openvr_driver.h"
#endif
#include "pose_math.h"
#include "protocol.h"
#include "udp_link.h"

#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#if defined(_WIN32)
#define HMD_DLL_EXPORT extern "C" __declspec(dllexport)
#else
#define HMD_DLL_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
const char *kSection = "driver_phonevr";

void Log(const char *fmt, ...) {
  char buf[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  vr::VRDriverLog()->Log(buf);
}

float GetFloatSetting(const char *key, float fallback) {
  vr::EVRSettingsError err = vr::VRSettingsError_None;
  float v = vr::VRSettings()->GetFloat(kSection, key, &err);
  return err == vr::VRSettingsError_None ? v : fallback;
}

int GetIntSetting(const char *key, int fallback) {
  vr::EVRSettingsError err = vr::VRSettingsError_None;
  int v = vr::VRSettings()->GetInt32(kSection, key, &err);
  return err == vr::VRSettingsError_None ? v : fallback;
}

bool GetBoolSetting(const char *key, bool fallback) {
  vr::EVRSettingsError err = vr::VRSettingsError_None;
  bool v = vr::VRSettings()->GetBool(kSection, key, &err);
  return err == vr::VRSettingsError_None ? v : fallback;
}

std::string GetStringSetting(const char *key, const char *fallback) {
  char buf[256];
  vr::EVRSettingsError err = vr::VRSettingsError_None;
  vr::VRSettings()->GetString(kSection, key, buf, sizeof(buf), &err);
  return err == vr::VRSettingsError_None && buf[0] ? std::string(buf)
                                                   : std::string(fallback);
}

struct DriverConfig {
  std::string serial = "PHONEVR-0001";
  std::string model = "PhoneVR";
  int udpPort = 5555;
  int phoneConfigPort = 5001;
  int windowX = 0, windowY = 0, windowW = 2992, windowH = 1344;
  float renderScale = 1.0f;
  float fovHDeg = 100.0f;
  float displayHz = 120.0f;
  float latencyMs = 40.0f;
  float ipdMm = 63.0f;
  float headHeightM = 1.2f;
  bool neckModel = true;
  float neckUpM = 0.075f;
  float neckForwardM = 0.080f;

  int eyeW() const { return windowW / 2; }
  int eyeH() const { return windowH; }
  float tanHalfX() const {
    return static_cast<float>(std::tan(fovHDeg * 3.14159265358979 / 360.0));
  }
  // Square pixels: vertical half-FOV tangent follows the eye image aspect
  // ratio.
  float tanHalfY() const {
    return tanHalfX() * static_cast<float>(eyeH()) / static_cast<float>(eyeW());
  }
};

DriverConfig LoadConfig() {
  DriverConfig c;
  c.serial = GetStringSetting("serial_number", c.serial.c_str());
  c.model = GetStringSetting("model_number", c.model.c_str());
  c.udpPort = GetIntSetting("udp_port", c.udpPort);
  c.phoneConfigPort = GetIntSetting("phone_config_port", c.phoneConfigPort);
  c.windowX = GetIntSetting("window_x", c.windowX);
  c.windowY = GetIntSetting("window_y", c.windowY);
  c.windowW = GetIntSetting("window_width", c.windowW) &
              ~1; // keep even so each eye is half
  c.windowH = GetIntSetting("window_height", c.windowH);
  c.renderScale = GetFloatSetting("render_scale", c.renderScale);
  c.fovHDeg = GetFloatSetting("fov_h_deg", c.fovHDeg);
  c.displayHz = GetFloatSetting("display_hz", c.displayHz);
  c.latencyMs = GetFloatSetting("latency_ms", c.latencyMs);
  c.ipdMm = GetFloatSetting("ipd_mm", c.ipdMm);
  c.headHeightM = GetFloatSetting("head_height_m", c.headHeightM);
  c.neckModel = GetBoolSetting("neck_model", c.neckModel);
  c.neckUpM = GetFloatSetting("neck_up_m", c.neckUpM);
  c.neckForwardM = GetFloatSetting("neck_forward_m", c.neckForwardM);
  return c;
}

// Where the start_stream script looks up the phone's address.
std::filesystem::path StateDir() {
  std::filesystem::path base;
  if (const char *local = std::getenv("LOCALAPPDATA"))
    base = std::filesystem::path(local) / "PhoneVR";
  else if (const char *home = std::getenv("HOME"))
    base = std::filesystem::path(home) / ".phonevr";
  else
    base = std::filesystem::temp_directory_path() / "PhoneVR";
  std::error_code ec;
  std::filesystem::create_directories(base, ec);
  return base;
}

void WritePhoneIp(const std::string &ip) {
  std::ofstream f(StateDir() / "phone_ip.txt", std::ios::trunc);
  f << ip << "\n";
}
} // namespace

//-----------------------------------------------------------------------------
// Display: a desktop window, both eyes side by side, no distortion.
//-----------------------------------------------------------------------------
class PhoneDisplay : public vr::IVRDisplayComponent {
public:
  explicit PhoneDisplay(const DriverConfig &c) : c_(c) {}

  void GetWindowBounds(int32_t *x, int32_t *y, uint32_t *w,
                       uint32_t *h) override {
    *x = c_.windowX;
    *y = c_.windowY;
    *w = c_.windowW;
    *h = c_.windowH;
  }
  bool IsDisplayOnDesktop() override { return true; }
  bool IsDisplayRealDisplay() override { return false; }

  void GetRecommendedRenderTargetSize(uint32_t *w, uint32_t *h) override {
    *w = static_cast<uint32_t>(c_.eyeW() * c_.renderScale) & ~1u;
    *h = static_cast<uint32_t>(c_.eyeH() * c_.renderScale) & ~1u;
  }

  void GetEyeOutputViewport(vr::EVREye eye, uint32_t *x, uint32_t *y,
                            uint32_t *w, uint32_t *h) override {
    *x = eye == vr::Eye_Left ? 0 : c_.eyeW();
    *y = 0;
    *w = c_.eyeW();
    *h = c_.eyeH();
  }

  void GetProjectionRaw(vr::EVREye, float *left, float *right, float *top,
                        float *bottom) override {
    *left = -c_.tanHalfX();
    *right = c_.tanHalfX();
    *top =
        -c_.tanHalfY(); // OpenVR convention: top is negative, bottom positive
    *bottom = c_.tanHalfY();
  }

  vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye, float u,
                                                float v) override {
    vr::DistortionCoordinates_t d{};
    d.rfRed[0] = d.rfGreen[0] = d.rfBlue[0] = u;
    d.rfRed[1] = d.rfGreen[1] = d.rfBlue[1] = v;
    return d;
  }

  bool ComputeInverseDistortion(vr::HmdVector2_t *, vr::EVREye, uint32_t, float,
                                float) override {
    return false;
  }

private:
  DriverConfig c_;
};

//-----------------------------------------------------------------------------
// The HMD itself.
//-----------------------------------------------------------------------------
class PhoneHmd : public vr::ITrackedDeviceServerDriver {
public:
  explicit PhoneHmd(const DriverConfig &c)
      : c_(c), display_(c), wantedIpdMm_(c.ipdMm), appliedIpdMm_(c.ipdMm) {
    pose_ = IdlePose();
  }

  const std::string &Serial() const { return c_.serial; }

  vr::EVRInitError Activate(uint32_t id) override {
    id_ = id;
    container_ = vr::VRProperties()->TrackedDeviceToPropertyContainer(id_);

    vr::VRProperties()->SetStringProperty(
        container_, vr::Prop_ModelNumber_String, c_.model.c_str());
    vr::VRProperties()->SetStringProperty(
        container_, vr::Prop_ManufacturerName_String, "PhoneVR");
    vr::VRProperties()->SetFloatProperty(
        container_, vr::Prop_UserIpdMeters_Float, c_.ipdMm / 1000.0f);
    vr::VRProperties()->SetFloatProperty(
        container_, vr::Prop_DisplayFrequency_Float, c_.displayHz);
    vr::VRProperties()->SetFloatProperty(
        container_, vr::Prop_UserHeadToEyeDepthMeters_Float, 0.f);
    vr::VRProperties()->SetFloatProperty(
        container_, vr::Prop_SecondsFromVsyncToPhotons_Float,
        c_.latencyMs / 1000.0f);
    vr::VRProperties()->SetBoolProperty(container_, vr::Prop_IsOnDesktop_Bool,
                                        true);
    vr::VRProperties()->SetBoolProperty(container_,
                                        vr::Prop_DisplayDebugMode_Bool, true);
    vr::VRProperties()->SetStringProperty(
        container_, vr::Prop_InputProfilePath_String,
        "{phonevr}/input/phonevr_profile.json");
    vr::VRDriverInput()->CreateBooleanComponent(
        container_, "/input/system/touch", &systemTouch_);
    vr::VRDriverInput()->CreateBooleanComponent(
        container_, "/input/system/click", &systemClick_);

    std::string err;
    bool ok = link_.Start(
        static_cast<uint16_t>(c_.udpPort),
        [this](const phonevr::PosePacket &p) { OnPosePacket(p); },
        [this](const std::string &ip) {
          Log("phone connected from %s", ip.c_str());
          WritePhoneIp(ip);
          autoRecenter_ = true;
          sendConfigNow_ = true;
        },
        &err);
    if (!ok)
      Log("UDP listener failed: %s (head tracking will not work)", err.c_str());
    else
      Log("listening for the phone on UDP %d; window %dx%d at (%d,%d); fov_h "
          "%.0f deg",
          c_.udpPort, c_.windowW, c_.windowH, c_.windowX, c_.windowY,
          c_.fovHDeg);

    active_ = true;
    thread_ = std::thread(&PhoneHmd::PoseThread, this);
    return vr::VRInitError_None;
  }

  void Deactivate() override {
    if (active_.exchange(false)) {
      cv_.notify_all();
      if (thread_.joinable())
        thread_.join();
    }
    link_.Stop();
    id_ = vr::k_unTrackedDeviceIndexInvalid;
  }

  void EnterStandby() override {}

  void *GetComponent(const char *name) override {
    if (std::strcmp(name, vr::IVRDisplayComponent_Version) == 0)
      return &display_;
    return nullptr;
  }

  void DebugRequest(const char *, char *resp, uint32_t size) override {
    if (size >= 1)
      resp[0] = 0;
  }

  vr::DriverPose_t GetPose() override {
    std::lock_guard<std::mutex> lock(poseMutex_);
    return pose_;
  }

private:
  static vr::DriverPose_t BasePose() {
    vr::DriverPose_t p = {0};
    p.qWorldFromDriverRotation.w = 1.0;
    p.qDriverFromHeadRotation.w = 1.0;
    p.qRotation.w = 1.0;
    p.poseIsValid = true;
    p.deviceIsConnected = true;
    p.result = vr::TrackingResult_Running_OK;
    p.willDriftInYaw = true; // game rotation vector has no absolute heading
    p.shouldApplyHeadModel = false; // we apply our own neck model below
    return p;
  }

  vr::DriverPose_t IdlePose() const {
    vr::DriverPose_t p = BasePose();
    p.vecPosition[1] = c_.headHeightM;
    return p;
  }

  // Runs on the UDP receive thread.
  void OnPosePacket(const phonevr::PosePacket &pk) {
    using namespace phonevr;
    const bool landscapeRight = (pk.flags & kFlagLandscapeRight) != 0;
    const Quat q{pk.q[0], pk.q[1], pk.q[2], pk.q[3]};
    if (!std::isfinite(q.x + q.y + q.z + q.w))
      return;

    const bool recenterFlag = (pk.flags & kFlagRecenter) != 0;
    const bool recenterEdge = recenterFlag && !prevRecenterFlag_;
    prevRecenterFlag_ = recenterFlag;

    const Mat3 raw = tracker_.Raw(q, landscapeRight);
    if (autoRecenter_ || recenterEdge) {
      if (tracker_.Recenter(raw))
        autoRecenter_ = false;
    }
    const Mat3 head = tracker_.Apply(raw);
    const Quat hq = ToQuat(head);

    vr::DriverPose_t p = BasePose();
    p.qRotation.w = hq.w;
    p.qRotation.x = hq.x;
    p.qRotation.y = hq.y;
    p.qRotation.z = hq.z;

    double px = 0, py = c_.headHeightM, pz = 0;
    if (c_.neckModel) {
      // Eyes sit in front of and above the neck pivot, so turning the head
      // moves them a little.
      const Vec3 off{0.0, c_.neckUpM, -c_.neckForwardM};
      const Vec3 r = Mul(head, off);
      px += r.x - off.x;
      py += r.y - off.y;
      pz += r.z - off.z;
    }
    p.vecPosition[0] = px;
    p.vecPosition[1] = py;
    p.vecPosition[2] = pz;

    const double gyro[3] = {pk.gyro[0], pk.gyro[1], pk.gyro[2]};
    const Vec3 w = GyroToWorld(head, gyro, landscapeRight);
    if (std::isfinite(w.x + w.y + w.z)) {
      p.vecAngularVelocity[0] = w.x;
      p.vecAngularVelocity[1] = w.y;
      p.vecAngularVelocity[2] = w.z;
    }

    {
      std::lock_guard<std::mutex> lock(poseMutex_);
      pose_ = p;
      dirty_ = true;
      if (std::isfinite(pk.ipdMm) && pk.ipdMm >= 40.0f && pk.ipdMm <= 80.0f)
        wantedIpdMm_ = pk.ipdMm;
    }
    cv_.notify_one();
  }

  void ApplyIpd(float ipdMm) {
    const float half = ipdMm / 2000.0f; // metres per eye
    vr::HmdMatrix34_t left = {{{1, 0, 0, -half}, {0, 1, 0, 0}, {0, 0, 1, 0}}};
    vr::HmdMatrix34_t right = {{{1, 0, 0, half}, {0, 1, 0, 0}, {0, 0, 1, 0}}};
    vr::VRServerDriverHost()->SetDisplayEyeToHead(id_, left, right);
    vr::VRProperties()->SetFloatProperty(
        container_, vr::Prop_UserIpdMeters_Float, ipdMm / 1000.0f);
    appliedIpdMm_ = ipdMm;
    Log("IPD set to %.1f mm", ipdMm);
  }

  void SendConfig() {
    phonevr::ConfigPacket cfg{};
    cfg.magic = phonevr::kConfigMagic;
    cfg.version = phonevr::kProtocolVersion;
    cfg.tanHalfX = c_.tanHalfX();
    cfg.tanHalfY = c_.tanHalfY();
    cfg.eyeWidth = static_cast<uint16_t>(c_.eyeW());
    cfg.eyeHeight = static_cast<uint16_t>(c_.eyeH());
    cfg.displayHz = c_.displayHz;
    cfg.appliedIpdMm = appliedIpdMm_;
    link_.SendConfig(cfg, static_cast<uint16_t>(c_.phoneConfigPort));
  }

  // All calls into vrserver happen on this one thread.
  void PoseThread() {
    auto lastConfig =
        std::chrono::steady_clock::now() - std::chrono::seconds(10);
    while (active_) {
      vr::DriverPose_t pose;
      float wantIpd;
      {
        std::unique_lock<std::mutex> lock(poseMutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(8),
                     [this] { return dirty_ || !active_; });
        if (!active_)
          break;
        dirty_ = false;
        pose = pose_;
        wantIpd = wantedIpdMm_;
      }

      if (std::fabs(wantIpd - appliedIpdMm_) > 0.05f)
        ApplyIpd(wantIpd);

      vr::VRServerDriverHost()->TrackedDevicePoseUpdated(
          id_, pose, sizeof(vr::DriverPose_t));

      const auto now = std::chrono::steady_clock::now();
      if (sendConfigNow_.exchange(false) ||
          now - lastConfig > std::chrono::seconds(1)) {
        SendConfig();
        lastConfig = now;
      }
    }
  }

  DriverConfig c_;
  PhoneDisplay display_;
  phonevr::UdpLink link_;
  phonevr::HeadPoseTracker tracker_; // only touched from the UDP thread

  uint32_t id_ = vr::k_unTrackedDeviceIndexInvalid;
  vr::PropertyContainerHandle_t container_ = vr::k_ulInvalidPropertyContainer;
  vr::VRInputComponentHandle_t systemTouch_ =
      vr::k_ulInvalidInputComponentHandle;
  vr::VRInputComponentHandle_t systemClick_ =
      vr::k_ulInvalidInputComponentHandle;

  std::mutex poseMutex_;
  std::condition_variable cv_;
  vr::DriverPose_t pose_{};
  bool dirty_ = false;
  float wantedIpdMm_;
  float appliedIpdMm_; // PoseThread only

  std::atomic<bool> active_{false};
  std::atomic<bool> autoRecenter_{true};
  std::atomic<bool> sendConfigNow_{false};
  bool prevRecenterFlag_ = false; // UDP thread only
  std::thread thread_;
};

//-----------------------------------------------------------------------------
// Provider (entry point used by vrserver).
//-----------------------------------------------------------------------------
class PhoneProvider : public vr::IServerTrackedDeviceProvider {
public:
  vr::EVRInitError Init(vr::IVRDriverContext *ctx) override {
    VR_INIT_SERVER_DRIVER_CONTEXT(ctx);
    const DriverConfig cfg = LoadConfig();
    hmd_ = std::make_unique<PhoneHmd>(cfg);
    if (!vr::VRServerDriverHost()->TrackedDeviceAdded(
            hmd_->Serial().c_str(), vr::TrackedDeviceClass_HMD, hmd_.get())) {
      Log("TrackedDeviceAdded failed");
      return vr::VRInitError_Driver_Unknown;
    }
    return vr::VRInitError_None;
  }

  void Cleanup() override { hmd_.reset(); }
  const char *const *GetInterfaceVersions() override {
    return vr::k_InterfaceVersions;
  }

  void RunFrame() override {
    vr::VREvent_t ev{};
    while (vr::VRServerDriverHost()->PollNextEvent(&ev, sizeof(ev))) {
    }
  }

  bool ShouldBlockStandbyMode() override { return false; }
  void EnterStandby() override {}
  void LeaveStandby() override {}

private:
  std::unique_ptr<PhoneHmd> hmd_;
};

PhoneProvider g_provider;

HMD_DLL_EXPORT void *HmdDriverFactory(const char *name, int *returnCode) {
  if (std::strcmp(vr::IServerTrackedDeviceProvider_Version, name) == 0)
    return &g_provider;
  if (returnCode)
    *returnCode = vr::VRInitError_Init_InterfaceNotFound;
  return nullptr;
}
