#include "audio_devices.h"

#include <pulse/error.h>
#include <pulse/introspect.h>
#include <pulse/pulseaudio.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

struct AudioDeviceEntry {
  std::string id;
  std::string name;
  bool is_default = false;
};

struct DeviceListState {
  pa_mainloop* mainloop = nullptr;
  pa_context* context = nullptr;
  std::vector<AudioDeviceEntry> devices;
  std::string default_source;
  bool done = false;
  bool success = false;
  std::string error;
};

void Finish(DeviceListState* state, bool success) {
  state->success = success;
  state->done = true;
  if (state->mainloop != nullptr) {
    pa_mainloop_quit(state->mainloop, 0);
  }
}

void ContextStateCallback(pa_context* context, void* userdata) {
  auto* state = static_cast<DeviceListState*>(userdata);
  switch (pa_context_get_state(context)) {
    case PA_CONTEXT_READY: {
      pa_context_get_server_info(
          context,
          [](pa_context* ctx, const pa_server_info* info, void* data) {
            auto* st = static_cast<DeviceListState*>(data);
            if (info != nullptr && info->default_source_name != nullptr) {
              st->default_source = info->default_source_name;
            }
            pa_context_get_source_info_list(
                ctx,
                [](pa_context* c, const pa_source_info* i, int eol, void* d) {
                  auto* st = static_cast<DeviceListState*>(d);
                  if (eol > 0) {
                    Finish(st, true);
                    return;
                  }
                  if (i == nullptr) {
                    return;
                  }
                  const std::string id = i->name != nullptr ? i->name : "";
                  if (id.empty() ||
                      (id.size() >= 8 &&
                       id.compare(id.size() - 8, 8, ".monitor") == 0)) {
                    return;
                  }
                  AudioDeviceEntry entry;
                  entry.id = id;
                  entry.name =
                      i->description != nullptr ? i->description : id;
                  entry.is_default = false;
                  st->devices.push_back(std::move(entry));
                },
                st);
          },
          state);
      break;
    }
    case PA_CONTEXT_FAILED:
      state->error = pa_strerror(pa_context_errno(context));
      Finish(state, false);
      break;
    case PA_CONTEXT_TERMINATED:
      Finish(state, false);
      break;
    default:
      break;
  }
}

bool ListDevices(std::vector<AudioDeviceEntry>* out, std::string* error_out) {
  DeviceListState state;
  state.mainloop = pa_mainloop_new();
  if (state.mainloop == nullptr) {
    if (error_out) {
      *error_out = "Failed to create PulseAudio mainloop";
    }
    return false;
  }

  state.context = pa_context_new(pa_mainloop_get_api(state.mainloop),
                                 "prysm-linux-audio-devices");
  if (state.context == nullptr) {
    pa_mainloop_free(state.mainloop);
    if (error_out) {
      *error_out = "Failed to create PulseAudio context";
    }
    return false;
  }

  pa_context_set_state_callback(state.context, ContextStateCallback, &state);
  if (pa_context_connect(state.context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) <
      0) {
    if (error_out) {
      *error_out = pa_strerror(pa_context_errno(state.context));
    }
    pa_context_unref(state.context);
    pa_mainloop_free(state.mainloop);
    return false;
  }

  int ret = 0;
  if (pa_mainloop_run(state.mainloop, &ret) < 0) {
    if (error_out) {
      *error_out = "PulseAudio mainloop failed";
    }
    pa_context_disconnect(state.context);
    pa_context_unref(state.context);
    pa_mainloop_free(state.mainloop);
    return false;
  }

  const bool ok = state.success;
  if (!ok && error_out != nullptr && !state.error.empty()) {
    *error_out = state.error;
  }

  if (ok) {
  for (auto& device : state.devices) {
      if (!state.default_source.empty() && device.id == state.default_source) {
        device.is_default = true;
      }
    }
    *out = std::move(state.devices);
  }

  pa_context_disconnect(state.context);
  pa_context_unref(state.context);
  pa_mainloop_free(state.mainloop);
  return ok;
}

}  // namespace

FlValue* prysm_list_input_devices() {
  std::vector<AudioDeviceEntry> devices;
  std::string error;
  if (!ListDevices(&devices, &error)) {
    g_warning("prysm_linux_audio: listInputDevices failed: %s",
              error.c_str());
    return fl_value_new_list();
  }

  FlValue* list = fl_value_new_list();
  for (const auto& device : devices) {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "id", fl_value_new_string(device.id.c_str()));
    fl_value_set_string_take(map, "name",
                             fl_value_new_string(device.name.c_str()));
    fl_value_set_string_take(map, "isDefault",
                             fl_value_new_bool(device.is_default));
    fl_value_append_take(list, map);
  }
  return list;
}
