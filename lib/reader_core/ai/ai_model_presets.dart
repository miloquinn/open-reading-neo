// 文件说明：AI 模型预设目录，集中维护内置供应商、模型与默认参数。
// 技术要点：静态预设、Provider 默认选择、配置匹配与过滤。

part of 'ai_service.dart';

class AIModelPreset {
  final String id;
  final String label;
  final String vendor;
  final AIProviderType provider;
  final String baseUrl;
  final String model;
  final double temperature;

  const AIModelPreset({
    required this.id,
    required this.label,
    required this.vendor,
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
  });

  AIProviderSettings toSettings({String apiKey = ''}) {
    return AIProviderSettings(
      provider: provider,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      temperature: temperature,
    ).normalized();
  }
}

class AIModelPresets {
  static const List<AIModelPreset> all = <AIModelPreset>[
    AIModelPreset(
      id: 'openai_gpt_4o_mini',
      label: 'GPT-4o mini',
      vendor: 'OpenAI',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'openai_gpt_4o',
      label: 'GPT-4o',
      vendor: 'OpenAI',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'openai_gpt_4_1_mini',
      label: 'GPT-4.1 mini',
      vendor: 'OpenAI',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4.1-mini',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'openai_gpt_4_1',
      label: 'GPT-4.1',
      vendor: 'OpenAI',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4.1',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'glm_4_flash',
      label: 'GLM-4-Flash',
      vendor: '智谱 GLM',
      provider: AIProviderType.glm,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-flash',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'glm_4_plus',
      label: 'GLM-4-Plus',
      vendor: '智谱 GLM',
      provider: AIProviderType.glm,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-plus',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'minimax_m2_5',
      label: 'MiniMax-M2.5',
      vendor: 'MiniMax',
      provider: AIProviderType.minimax,
      baseUrl: 'https://api.minimax.io/v1',
      model: 'MiniMax-M2.5',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'claude_sonnet',
      label: 'Claude Sonnet',
      vendor: 'Anthropic',
      provider: AIProviderType.claude,
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-3-5-sonnet-latest',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'claude_haiku',
      label: 'Claude Haiku',
      vendor: 'Anthropic',
      provider: AIProviderType.claude,
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-3-5-haiku-latest',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'gemini_2_flash',
      label: 'Gemini 2.0 Flash',
      vendor: 'Google',
      provider: AIProviderType.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      model: 'gemini-2.0-flash',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'gemini_2_5_pro',
      label: 'Gemini 2.5 Pro',
      vendor: 'Google',
      provider: AIProviderType.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      model: 'gemini-2.5-pro',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'deepseek_chat',
      label: 'DeepSeek Chat',
      vendor: 'DeepSeek(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'deepseek_reasoner',
      label: 'DeepSeek Reasoner',
      vendor: 'DeepSeek(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-reasoner',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'qwen_plus',
      label: 'Qwen Plus',
      vendor: '阿里云百炼(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen-plus',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'qwen_max',
      label: 'Qwen Max',
      vendor: '阿里云百炼(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen-max',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'kimi_8k',
      label: 'Moonshot 8k',
      vendor: 'Moonshot(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-8k',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'kimi_32k',
      label: 'Moonshot 32k',
      vendor: 'Moonshot(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-32k',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'groq_llama_70b',
      label: 'Llama 3.3 70B',
      vendor: 'Groq(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.groq.com/openai/v1',
      model: 'llama-3.3-70b-versatile',
      temperature: 0.7,
    ),
    AIModelPreset(
      id: 'siliconflow_qwen_72b',
      label: 'Qwen2.5 72B',
      vendor: 'SiliconFlow(OpenAI兼容)',
      provider: AIProviderType.openai,
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Qwen/Qwen2.5-72B-Instruct',
      temperature: 0.7,
    ),
  ];

  static AIModelPreset defaultForProvider(AIProviderType provider) {
    return all.firstWhere(
      (p) => p.provider == provider,
      orElse: () => all.first,
    );
  }

  static AIModelPreset? match(AIProviderSettings settings) {
    final normalizedBase = settings.baseUrl.trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final normalizedModel = settings.model.trim();
    for (final preset in all) {
      final presetBase = preset.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (preset.provider == settings.provider &&
          presetBase == normalizedBase &&
          preset.model == normalizedModel) {
        return preset;
      }
    }
    return null;
  }

  static List<AIModelPreset> byProvider(AIProviderType provider) {
    return all.where((preset) => preset.provider == provider).toList();
  }
}
