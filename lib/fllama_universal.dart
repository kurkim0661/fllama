import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:fllama/fllama.dart';
import 'package:fllama/misc/gbnf.dart';
import 'package:jinja/jinja.dart';

import 'fllama_io.dart';
import 'model/model_override.dart';

/// Returns true if the given [output] indicates that the model failed to load.
/// Output is the output from [fllamaInference] or [fllamaChat].
bool fllamaOutputIndicatesLoadError(String output) {
  return output.contains('Error: Unable to load model.');
}

/// [String]s to use in [OpenAiRequest.modelPath] on web when using MLC's web
/// inference SDK.
class MlcModelId {
  const MlcModelId._();

  static const String qwen05b = "Qwen2-0.5B-Instruct-q4f16_1-MLC";
  static const String llama321bInstruct = "Llama-3.2-1B-Instruct-q4f16_1-MLC";
  static const String llama323bInstruct = "Llama-3.2-3B-Instruct-q4f16_1-MLC";
  static const String llama38bInstruct = "Llama-3-8B-Instruct-q4f16_1-MLC";
  static const String llama318bInstruct = "Llama-3.1-8B-Instruct-q4f16_1-MLC";
  static const String tinyLlama = "TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC";
  static const String phi3mini = "Phi-3-mini-4k-instruct-q4f16_1-MLC";
  static const String phi35mini = "Phi-3.5-mini-instruct-q4f16_1-MLC";
  static const String openHermesMistral =
      "OpenHermes-2.5-Mistral-7B-q4f16_1-MLC";
  static const String openHermesLlama38b =
      "Hermes-2-Pro-Llama-3-8B-q4f16_1-MLC";
  static const String deepSeekR1Llama38b =
      "DeepSeek-R1-Distill-Llama-8B-q4f16_1-MLC";
}

/// Parameters needed to run standard LLM inference. Use with [fllamaInference].
///
/// This is *not* what most people want to use. LLMs post-ChatGPT use a chat
/// template and an EOS token. Use [fllamaChat] instead if you expect this
/// sort of interface, i.e. an OpenAI-like API. It translates an OpenAI-like
/// request into a inference request.
class FllamaInferenceRequest {
  int
  contextSize; // llama.cpp handled 0 fine. StableLM Zephyr became default (4096).
  String input;
  int maxTokens;
  String modelPath;
  String? modelMmprojPath;
  String? openAiRequestJsonString;
  int numGpuLayers;

  /// Number of threads to use for inference.
  ///
  /// 2 by default based on testing performed 2024 Feb 15, and model loading
  /// taking ~3 minutes when thread count exceeds 2 on Pixel Fold.
  ///
  /// See class code for benchmarks from 2024 Feb 15.
  // Pixel Fold x StableLM 3B Zephyr, 2024 Feb 15:
  // - 99 gpu layers works, doesn't seem to affect performance or system load.
  // - default of 4 threads makes model loading take forever
  // - 1 thread / 0 layers: 4.7
  // - 1 thread / 99 layers: 4.5
  // - 2 threads / 0 layers: 7.7
  // M2 Ultra MBP 2024 x LLaVA 1.6 Mistral 7B, 2024 Feb 15:
  // - 2 threads / 0 layers: 6.54
  // - 2 threads / 99 layers: 38.9
  // - 4 threads / 99 layers: 35.5
  // - 8 threads / 99 layers: 38.9
  int numThreads;
  double temperature;
  double penaltyFrequency;
  double penaltyRepeat;
  double topP;
  String? grammar;
  Function(String)? logger;
  String? eosToken;

  FllamaInferenceRequest({
    required this.contextSize,
    required this.input,
    required this.maxTokens,
    required this.modelPath,
    required this.numGpuLayers,
    required this.penaltyFrequency,
    required this.penaltyRepeat,
    required this.temperature,
    required this.topP,
    this.grammar,
    this.eosToken,
    this.modelMmprojPath,
    this.numThreads = 2,
    this.logger,
    this.openAiRequestJsonString,
  });
}

/// Represents a request to tokenize a string.
///
/// This is useful for identifying what messages will be in context when the LLM
/// is run. Use with [fllamaTokenize].
class FllamaTokenizeRequest {
  final String input;
  final String modelPath;

  FllamaTokenizeRequest({required this.input, required this.modelPath});
}

/// Run the LLM using the standard LLM chat interface. This is the most common
/// way to use FLLAMA.
///
/// What is the difference between this and inference? It automatically handles:
/// - Using the chat template in the GGUF (fallback to ChatML if none is found).
/// - Using the EOS token in the GGUF (fallback to ChatML EOS if none is found).
/// - If a tool / function is supplied, force the model to only output JSON that
///   is valid according to the tool's JSON schema.
Future<int> fllamaChat(
  OpenAiRequest request,
  FllamaInferenceCallback callback,
) async {
  final String text;
  final String eosToken;
  final String bosToken;
  final String chatTemplate;

  chatTemplate = '';
  // fllamaSanitizeChatTemplate(
  //   await fllamaChatTemplateGet(request.modelPath),
  //   request.modelPath,
  // );
  eosToken = '';
  // chatTemplate == chatMlTemplate
  //     ? chatMlEosToken
  //     : await fllamaEosTokenGet(request.modelPath);
  bosToken = '';

  //  chatTemplate == chatMlTemplate
  //     ? chatMlBosToken
  //     : await fllamaBosTokenGet(request.modelPath);

  text =
      '' ??
      fllamaApplyChatTemplate(
        chatTemplate: chatTemplate,
        bosToken: bosToken,
        eosToken: eosToken,
        request: request,
      );

  final inferenceRequest = FllamaInferenceRequest(
    contextSize: request.contextSize,
    input: text,
    maxTokens: request.maxTokens,
    modelPath: request.modelPath,
    modelMmprojPath: request.mmprojPath,
    numGpuLayers: request.numGpuLayers,
    penaltyFrequency: request.frequencyPenalty,
    penaltyRepeat: request.presencePenalty,
    temperature: request.temperature,
    topP: request.topP,
    grammar: '', // deprecated, llama.cpp handles tools internally now
    logger: request.logger,
    eosToken: eosToken,
    openAiRequestJsonString: request.toJsonString(),
  );

  return fllamaInference(inferenceRequest, callback);
}

/// Returns a string representing the input to an LLM model after applying the
/// chat template.
///
/// - [chatTemplate] is the raw chat template from the GGUF.
/// - [eosToken] is the raw EOS token from the GGUF.
/// - [request] is the OpenAI-like request.
String fllamaApplyChatTemplate({
  required String chatTemplate,
  required OpenAiRequest request,
  required String bosToken,
  required String eosToken,
}) {
  final jsonMessages = <Map<String, dynamic>>[];
  for (final message in request.messages) {
    jsonMessages.add({
      'role': message.role.openAiName,
      'content': message.text,
    });
  }

  if (request.tools.isNotEmpty) {
    //     final tools = request.tools.map((tool) {
    //       return tool.typescriptDefinition;
    //     }).join('\n\n');
    //     jsonMessages.insert(0, {
    //       'role': 'system',
    //       'content': '''
    // You have access to the following functions:
    // $tools

    // You are a helpful assistant with tool calling capabilities.
    // When you receive a tool call response, use the output to format an answer to the orginal use question.
    // If you are using tools, respond in the format {"name": function name, "parameters": dictionary of function arguments}. If multiple tools are used, use array format.
    // ''',
    //     });
  }

  if (jsonMessages.isEmpty) {
    // Add dummy message.
    // Gemma 1.1's chat template accesses messages[0] without a condition on it
    // being empty.
    jsonMessages.add({'role': 'user', 'content': ''});
  }

  // There's a strange chat template first encountered in an early version of
  // LLaVa 1.6 x Mistral 7B.
  //
  // It is likely to be some sort of default template used by .gguf makers.
  //
  // It has a raise_exception function that is not defined in the template,
  // so it will cause an error.
  //
  // The template in the LLaVA 1.6 model model was incorrect in several ways,
  // and currently templates like it (templates that contain only user and
  // assistant roles are supported) are replaced with ChatML.
  //
  // However, it seems sensible to maintain this error.
  final globals = <String, Function>{
    'raise_exception': (String message) {
      // ignore: avoid_print
      print('[fllama] chat template asked to raise_exception: $message');
      return '';
    },
  };

  // Workaround in case of Jinja2 exception.
  // Motivation: bartowski's dolphin 2.8 experiment 26
  // Error: flutter: [fllama] Using ChatML because the chat template could not be applied. Exception: TemplateSyntaxError: Expected token rbracket, got :. Chat template: {% if messages[0]['role'] == 'system' %}{% set loop_messages = messages[1:] %}{% set system_message = messages[0]['content'] %}{% else %}{% set loop_messages = messages %}{% set system_message = 'You are a helpful assistant.' %}{% endif %}{% if not add_generation_prompt is defined %}{% set add_generation_prompt = false %}{% endif %}{% for message in loop_messages %}{% if loop.index0 == 0 %}{{'<|im_start|>system
  try {
    final env = Environment(
      globals: globals,
      loader: null,
      leftStripBlocks: true,
      trimBlocks: true,
      keepTrailingNewLine: true,
    );

    final template = env.fromString(chatTemplate, globals: globals);
    return template.render({
      'messages': jsonMessages,
      'add_generation_prompt': true,
      'eos_token': eosToken,
      'bos_token': bosToken,
    });
  } catch (e) {
    // ignore: avoid_print
    print('[fllama] Error applying chat template: $e');
    // ignore: avoid_print
    print('[fllama] chat template: $chatTemplate');
    // ignore: avoid_print
    // print('[fllama] messages: $jsonMessages');
    if (chatTemplate != chatMlTemplate) {
      final llamaChatTemplate = Llama3ChatTemplate();
      // ignore: avoid_print
      if (llamaChatTemplate.matches(chatTemplate)) {
        // ex. bartowski's llama 3.2 8B cannot be parsed, but it is
        // desirable to use. ChatML as a fallback breaks it. First response
        // generally works, then it fails.

        return fllamaApplyChatTemplate(
          chatTemplate: llamaChatTemplate.template,
          request: request,
          bosToken: llamaChatTemplate.bosToken,
          eosToken: llamaChatTemplate.eosToken,
        );
      }
      return fllamaApplyChatTemplate(
        chatTemplate: chatMlTemplate,
        request: request,
        bosToken: bosToken,
        eosToken: eosToken,
      );
    } else {
      // ignore: avoid_print
      print(
        '[fllama] Exception thrown while applying chat template. ChatML could not be used as a fallback. Returning empty string. Exception: $e. Chat template: $chatTemplate. Messages: $jsonMessages.',
      );
      return '';
    }
  }
}

const chatMlTemplate = '''
{%- for msg in messages -%}
<|im_start|>{{ msg.role }}
{{ msg.content }}<|im_end|>
{% endfor %}
<|im_start|>assistant
''';

const chatMlBosToken = '<|im_start|>';
const chatMlEosToken = '<|im_end|>';

/// Convert a JSON schema to GBNF, a grammar format used by llama.cpp to enforce
/// that the model returns certain outputs.
String fllamaJsonSchemaToGrammar(String jsonSchema) {
  return convertToJsonGrammar(jsonSchema);
}

/// Given a chat template embedded in a .gguf file, returns the chat template
/// itself, or a sensible fallback if the chat template is incorrect or missing.
String fllamaSanitizeChatTemplate(
  String builtInChatTemplate,
  String modelPath,
) {
  final String chatTemplate;

  // Order is very important here, be careful.
  // ex. if isNotEmpty branch comes first, the check for an erroroneous
  // template never runs.
  if (builtInChatTemplate.contains(
    'Only user and assistant roles are supported!',
  )) {
    // There's a strange chat template first encountered in an early version of
    // LLaVa 1.6 x Mistral 7B.
    //
    // It is likely to be some sort of default template used by .gguf makers.
    //
    // It is too limited to be acceptable, as it strips out system messages.
    // Instead of using it, use ChatML.
    //
    // n.b. LLaVa 1.6 is actually supposed to use ChatML anyway, the template
    // in the model is incorrect.
    //
    // Template: ```{{ bos_token }}{% for message in messages %}{% if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}{{ raise_exception('Conversation roles must alternate user/assistant/user/assistant/...') }}{% endif %}{% if message['role'] == 'user' %}{{ '[INST] ' + message['content'] + ' [/INST]' }}{% elif message['role'] == 'assistant' %}{{ message['content'] + eos_token}}{% else %}{{ raise_exception('Only user and assistant roles are supported!') }}{% endif %}{% endfor %}```
    chatTemplate = chatMlTemplate;
    // ignore: avoid_print
    print(
      '[fllama] Using ChatML because built-in chat template seems erroneous. (contains "Only user and assistant roles are supported!")',
    );
  } else if (builtInChatTemplate.isNotEmpty) {
    // First observed with https://huggingface.co/brittlewis12/Memphis-CoT-3B-GGUF
    // Replacing with trim() did not work. That was unexpected because the Jinja
    // package seems to indicate Dart instance methods are available.
    chatTemplate = builtInChatTemplate.replaceAll('.strip()', '');
    // ignore: avoid_print
    print('[fllama] Using built-in chat template: $chatTemplate');
    // ignore: avoid_print
  } else {
    // Assume models without one specified intend ChatML.
    // This is the case for Mistral 7B via OpenHermes.
    // ignore: avoid_print
    print('[fllama] Using ChatML because no built-in chat template was found.');
    chatTemplate = chatMlTemplate;
  }
  return chatTemplate;
}

/// Clears the model cache used by fllama.
///
/// This function releases memory used by cached models.
/// Call this when you want to free up memory or when switching between models.
///
/// @param forceClean If true, forces clearing of the model cache even when in use
void fllamaClearModelCache({bool forceClean = false}) async {
  // Allocate memory for the boolean parameter
  final Pointer<Bool> forceCleanPointer = calloc<Bool>();
  // Set the value
  forceCleanPointer.value = forceClean ? true : false;

  try {
    fllamaBindings.fllama_clear_model_cache(forceCleanPointer);
  } finally {
    // Free the allocated memory
    calloc.free(forceCleanPointer);
  }
}

Future<void> fllamaClearModelCacheAsync({bool forceClean = false}) async {
  // Allocate memory for the boolean parameter
  final Pointer<Bool> forceCleanPointer = calloc<Bool>();
  // Set the value
  forceCleanPointer.value = forceClean ? true : false;

  try {
    fllamaBindings.fllama_clear_model_cache(forceCleanPointer);
  } finally {
    // Free the allocated memory
    calloc.free(forceCleanPointer);
  }
}