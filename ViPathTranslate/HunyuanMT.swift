import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// Port của mlx-lm `hunyuan_v1_dense.py` (Tencent Hunyuan-MT-7B) sang Swift.
// mlx-swift-lm 2.31.x chưa có kiến trúc này nên app tự đăng ký vào LLMTypeRegistry.
//
// Khác biệt so với Llama/Qwen3:
//  • RoPE kiểu "Dynamic NTK alpha": base = θ · α^(d/(d−2)), truyền thẳng mảng tần số vào fast.rope.
//  • Chuẩn hoá Q/K (query_layernorm / key_layernorm) đặt SAU RoPE, không phải trước như Qwen3.
//  • Embedding dùng chung với lm_head (tie_word_embeddings = true).

enum HunyuanRegistration {
    private static let done = OnceFlag()

    /// Gọi trước khi nạp mô hình; an toàn khi gọi nhiều lần.
    static func register() async {
        guard await done.claim() else { return }
        await LLMTypeRegistry.shared.registerModelType("hunyuan_v1_dense") { data in
            let config = try JSONDecoder().decode(HunyuanConfiguration.self, from: data)
            return HunyuanModel(config)
        }
    }

    private actor OnceFlag {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Cấu hình

public struct HunyuanConfiguration: Codable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var kvHeads: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var ropeTheta: Float
    var attentionBias: Bool
    var useQKNorm: Bool
    var tieWordEmbeddings: Bool
    var headDim: Int
    var ropeAlpha: Float

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case attentionBias = "attention_bias"
        case useQKNorm = "use_qk_norm"
        case tieWordEmbeddings = "tie_word_embeddings"
        case headDim = "head_dim"
        case ropeScaling = "rope_scaling"
    }

    /// Chỉ đọc `alpha`; các khoá khác trong rope_scaling (beta_fast, mscale…) không dùng.
    private struct RopeScaling: Codable {
        var alpha: Float?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        hiddenLayers = try c.decode(Int.self, forKey: .hiddenLayers)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        attentionHeads = try c.decode(Int.self, forKey: .attentionHeads)
        kvHeads = try c.decode(Int.self, forKey: .kvHeads)
        rmsNormEps = try c.decode(Float.self, forKey: .rmsNormEps)
        vocabularySize = try c.decode(Int.self, forKey: .vocabularySize)
        ropeTheta = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 10_000
        attentionBias = try c.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        useQKNorm = try c.decodeIfPresent(Bool.self, forKey: .useQKNorm) ?? true
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? (hiddenSize / attentionHeads)
        let scaling = try? c.decodeIfPresent(RopeScaling.self, forKey: .ropeScaling)
        ropeAlpha = scaling?.alpha ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hiddenSize, forKey: .hiddenSize)
        try c.encode(hiddenLayers, forKey: .hiddenLayers)
        try c.encode(intermediateSize, forKey: .intermediateSize)
        try c.encode(attentionHeads, forKey: .attentionHeads)
        try c.encode(kvHeads, forKey: .kvHeads)
        try c.encode(rmsNormEps, forKey: .rmsNormEps)
        try c.encode(vocabularySize, forKey: .vocabularySize)
        try c.encode(ropeTheta, forKey: .ropeTheta)
        try c.encode(attentionBias, forKey: .attentionBias)
        try c.encode(useQKNorm, forKey: .useQKNorm)
        try c.encode(tieWordEmbeddings, forKey: .tieWordEmbeddings)
        try c.encode(headDim, forKey: .headDim)
        try c.encode(RopeScaling(alpha: ropeAlpha), forKey: .ropeScaling)
    }
}

// MARK: - RoPE Dynamic NTK-alpha

final class HunyuanRoPE: Module {
    let dimensions: Int
    // Tiền tố "_": MLXNN bỏ qua khi dò tham số → không đòi khoá "rope.freqs" trong file trọng số.
    let _freqs: MLXArray

    init(dimensions: Int, base: Float, alpha: Float) {
        self.dimensions = dimensions
        // Tính bằng Double: α có thể tới 1e5 nên base mới ≈ 1e9.
        let d = Double(dimensions)
        let scaledBase = Double(base) * pow(Double(alpha), d / (d - 2))
        let values: [Float] = stride(from: 0, to: dimensions, by: 2).map {
            Float(pow(scaledBase, Double($0) / d))
        }
        self._freqs = MLXArray(values)
    }

    func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        MLXFast.RoPE(x, dimensions: dimensions, traditional: false,
                     base: nil, scale: 1.0, offset: offset, freqs: _freqs)
    }
}

// MARK: - Khối Transformer

final class HunyuanAttention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let scale: Float
    let useQKNorm: Bool

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    @ModuleInfo(key: "query_layernorm") var qNorm: RMSNorm?
    @ModuleInfo(key: "key_layernorm") var kNorm: RMSNorm?

    let rope: HunyuanRoPE

    init(_ args: HunyuanConfiguration) {
        heads = args.attentionHeads
        kvHeads = args.kvHeads
        headDim = args.headDim
        scale = pow(Float(args.headDim), -0.5)
        useQKNorm = args.useQKNorm

        let dim = args.hiddenSize
        _wq.wrappedValue = Linear(dim, heads * headDim, bias: args.attentionBias)
        _wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: args.attentionBias)
        _wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: args.attentionBias)
        _wo.wrappedValue = Linear(heads * headDim, dim, bias: args.attentionBias)
        if args.useQKNorm {
            _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
            _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        }
        rope = HunyuanRoPE(dimensions: headDim, base: args.ropeTheta, alpha: args.ropeAlpha)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode,
                        cache: KVCache?) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = wq(x).reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
        var keys = wk(x).reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)
        let values = wv(x).reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)

        let offset = cache?.offset ?? 0
        queries = rope(queries, offset: offset)
        keys = rope(keys, offset: offset)

        // Hunyuan: chuẩn hoá Q/K sau RoPE.
        if let qNorm, let kNorm {
            queries = qNorm(queries)
            keys = kNorm(keys)
        }

        let output = attentionWithCacheUpdate(
            queries: queries, keys: keys, values: values,
            cache: cache, scale: scale, mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }
}

final class HunyuanMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

final class HunyuanBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: HunyuanAttention
    let mlp: HunyuanMLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ args: HunyuanConfiguration) {
        _attention.wrappedValue = HunyuanAttention(args)
        mlp = HunyuanMLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode,
                        cache: KVCache?) -> MLXArray {
        let h = x + attention(inputLayerNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionLayerNorm(h))
    }
}

final class HunyuanInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [HunyuanBlock]
    let norm: RMSNorm

    init(_ args: HunyuanConfiguration) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabularySize,
                                              dimensions: args.hiddenSize)
        layers = (0 ..< args.hiddenLayers).map { _ in HunyuanBlock(args) }
        norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedTokens(inputs)
        let mask = createAttentionMask(h: h, cache: cache?.first)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }
        return norm(h)
    }
}

public final class HunyuanModel: Module, LLMModel, KVCacheDimensionProvider {
    public let vocabularySize: Int
    public let kvHeads: [Int]
    let configuration: HunyuanConfiguration

    let model: HunyuanInner
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ args: HunyuanConfiguration) {
        configuration = args
        vocabularySize = args.vocabularySize
        kvHeads = Array(repeating: args.kvHeads, count: args.hiddenLayers)
        model = HunyuanInner(args)
        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let out = model(inputs, cache: cache)
        if let lmHead { return lmHead(out) }
        return model.embedTokens.asLinear(out)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = weights
        if configuration.tieWordEmbeddings { weights["lm_head.weight"] = nil }
        return weights
    }

    public var loraLayers: [Module] { model.layers }
}
