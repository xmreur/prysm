#include "include/prysm_linux_audio/prysm_linux_audio_plugin.h"

#include "audio_devices.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>

struct _PrysmLinuxAudioPlugin {
  GObject parent_instance;
  FlMethodChannel* method_channel;
};

G_DEFINE_TYPE(PrysmLinuxAudioPlugin, prysm_linux_audio_plugin, g_object_get_type())

#define PRYSM_LINUX_AUDIO_PLUGIN(obj)                                         \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), prysm_linux_audio_plugin_get_type(),     \
                              PrysmLinuxAudioPlugin))

namespace {

constexpr char kMethodChannel[] = "prysm_linux_audio";

void HandleMethodCall(PrysmLinuxAudioPlugin* plugin, FlMethodCall* method_call) {
  (void)plugin;

  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "listInputDevices") == 0) {
    g_autoptr(FlValue) devices = prysm_list_input_devices();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(devices));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("prysm_linux_audio: failed to respond to method call: %s",
              error->message);
  }
}

void MethodCallHandler(FlMethodChannel* channel, FlMethodCall* method_call,
                       gpointer user_data) {
  (void)channel;
  HandleMethodCall(PRYSM_LINUX_AUDIO_PLUGIN(user_data), method_call);
}

}  // namespace

static void prysm_linux_audio_plugin_dispose(GObject* object) {
  PrysmLinuxAudioPlugin* plugin = PRYSM_LINUX_AUDIO_PLUGIN(object);
  g_clear_object(&plugin->method_channel);
  G_OBJECT_CLASS(prysm_linux_audio_plugin_parent_class)->dispose(object);
}

static void prysm_linux_audio_plugin_class_init(PrysmLinuxAudioPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = prysm_linux_audio_plugin_dispose;
}

static void prysm_linux_audio_plugin_init(PrysmLinuxAudioPlugin* plugin) {
  plugin->method_channel = nullptr;
}

void prysm_linux_audio_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  PrysmLinuxAudioPlugin* plugin = PRYSM_LINUX_AUDIO_PLUGIN(
      g_object_new(prysm_linux_audio_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  plugin->method_channel = fl_method_channel_new(messenger, kMethodChannel,
                                                FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->method_channel, MethodCallHandler, g_object_ref(plugin),
      g_object_unref);

  g_object_unref(plugin);
}
