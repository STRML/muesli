import Foundation
import MLX
import MLXFast
import MLXLLM
import MLXLMCommon
import MLXNN

// LFM3 (Liquid AI) text model, for the Phonon refiner cleanup model.
//
// mlx-swift-lm 3.32.3 has LFM2 but no `lfm3` model type, so Muesli registers this one
// with the factory (see `CleanupMLXEvaluation`). The architecture follows the public
// LFM3 reference in `transformers` (`modeling_lfm3.py`, Apache-2.0, shipped with
// LiquidAI/LFM3-1.7B) and the LFM2 port in mlx-swift-lm. Differences from LFM2:
//
// - a per-layer type: gated short conv, full attention, or sliding-window attention
// - a sigmoid output gate per attention head (`gate_proj`)
// - "sandwich" norms: an extra RMSNorm on the operator and feed-forward outputs
// - partial RoPE on full-attention layers: only the first quarter of the pairs rotate
//   (theta 1e6) and the rest are left alone; sliding layers rotate the whole head (theta 1e4)
// - tied embeddings (the output head is the quantized embedding)

struct LFM3Configuration: Decodable, Sendable {
    enum LayerType: String, Decodable, Sendable {
        case conv
        case fullAttention = "full_attention"
        case slidingAttention = "sliding_attention"

        var isAttention: Bool { self != .conv }
    }

    struct Rope: Decodable, Sendable {
        let theta: Float
        let partialRotaryFactor: Float
        let type: String

        enum CodingKeys: String, CodingKey {
            case theta = "rope_theta"
            case partialRotaryFactor = "partial_rotary_factor"
            case type = "rope_type"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            theta = try container.decode(Float.self, forKey: .theta)
            partialRotaryFactor = try container.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 1
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "default"
        }

        init(theta: Float, partialRotaryFactor: Float = 1) {
            self.theta = theta
            self.partialRotaryFactor = partialRotaryFactor
            type = "default"
        }
    }

    let vocabularySize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let hiddenLayers: Int
    let attentionHeads: Int
    let kvHeads: Int
    let headDim: Int
    let normEps: Float
    let convBias: Bool
    let convLCache: Int
    let layerTypes: [LayerType]
    let slidingWindow: Int
    let useSandwichNorm: Bool
    let fullAttentionRope: Rope
    let slidingAttentionRope: Rope

    enum CodingKeys: String, CodingKey {
        case vocabularySize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case hiddenLayers = "num_hidden_layers"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case normEps = "norm_eps"
        case convBias = "conv_bias"
        case convLCache = "conv_L_cache"
        case layerTypes = "layer_types"
        case slidingWindow = "sliding_window"
        case useSandwichNorm = "use_sandwich_norm"
        case ropeParameters = "rope_parameters"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vocabularySize = try container.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? 128_000
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 2048
        intermediateSize = try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 7680
        hiddenLayers = try container.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 24
        attentionHeads = try container.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 16
        kvHeads = try container.decodeIfPresent(Int.self, forKey: .kvHeads) ?? 4
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? (hiddenSize / attentionHeads)
        normEps = try container.decodeIfPresent(Float.self, forKey: .normEps) ?? 1e-5
        convBias = try container.decodeIfPresent(Bool.self, forKey: .convBias) ?? false
        convLCache = try container.decodeIfPresent(Int.self, forKey: .convLCache) ?? 7
        slidingWindow = try container.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 256
        useSandwichNorm = try container.decodeIfPresent(Bool.self, forKey: .useSandwichNorm) ?? true
        // The reference defaults: a full-attention layer every fourth layer from the third,
        // a sliding layer in between, short convs elsewhere.
        layerTypes = try container.decodeIfPresent([LayerType].self, forKey: .layerTypes)
            ?? (0 ..< hiddenLayers).map { i in
                i % 4 == 2 ? .fullAttention : (i % 4 == 0 && i > 0 ? .slidingAttention : .conv)
            }
        let ropes = try container.decodeIfPresent([String: Rope].self, forKey: .ropeParameters) ?? [:]
        fullAttentionRope = ropes["full_attention"] ?? Rope(theta: 1_000_000, partialRotaryFactor: 0.5)
        slidingAttentionRope = ropes["sliding_attention"] ?? Rope(theta: 10_000)
        try validate()
    }

    private func validate() throws {
        guard layerTypes.count == hiddenLayers else {
            throw ModelFactoryError.invalidConfiguration("lfm3: layer_types has \(layerTypes.count) entries for \(hiddenLayers) layers")
        }
        guard attentionHeads % kvHeads == 0, headDim % 2 == 0 else {
            throw ModelFactoryError.invalidConfiguration("lfm3: unsupported attention shape")
        }
        for rope in [fullAttentionRope, slidingAttentionRope] where rope.type != "default" {
            throw ModelFactoryError.invalidConfiguration("lfm3: unsupported rope type \(rope.type)")
        }
    }
}

/// RoPE over the whole head with the LFM3 zero tail: the first `partialRotaryFactor * headDim / 2`
/// pairs follow the full-head frequency progression and the rest do not rotate at all.
private func lfm3RopeFrequencies(headDim: Int, rope: LFM3Configuration.Rope) -> MLXArray? {
    let rotatedPairs = Int(rope.partialRotaryFactor * Float(headDim)) / 2
    guard rotatedPairs < headDim / 2 else { return nil }
    // `fast.rope` takes wavelengths; an infinite wavelength is a zero angle.
    let wavelengths = (0 ..< headDim / 2).map { pair -> Float in
        pair < rotatedPairs ? pow(rope.theta, Float(2 * pair) / Float(headDim)) : .infinity
    }
    return MLXArray(wavelengths)
}

final class LFM3Attention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let scale: Float
    let ropeBase: Float
    let _ropeFrequencies: MLXArray?

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    @ModuleInfo(key: "gate_proj") var gateProj: Linear

    init(_ args: LFM3Configuration, rope: LFM3Configuration.Rope) {
        heads = args.attentionHeads
        kvHeads = args.kvHeads
        headDim = args.headDim
        scale = pow(Float(args.headDim), -0.5)
        ropeBase = rope.theta
        _ropeFrequencies = lfm3RopeFrequencies(headDim: args.headDim, rope: rope)
        _qProj.wrappedValue = Linear(args.hiddenSize, heads * headDim, bias: false)
        _kProj.wrappedValue = Linear(args.hiddenSize, kvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(args.hiddenSize, kvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(heads * headDim, args.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.normEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.normEps)
        _gateProj.wrappedValue = Linear(args.hiddenSize, heads, bias: false)
    }

    private func rotate(_ x: MLXArray, offset: Int) -> MLXArray {
        MLXFast.RoPE(
            x, dimensions: headDim, traditional: false,
            base: _ropeFrequencies == nil ? ropeBase : nil, scale: 1, offset: offset,
            freqs: _ropeFrequencies)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        var queries = qNorm(qProj(x).reshaped(B, L, heads, -1)).transposed(0, 2, 1, 3)
        var keys = kNorm(kProj(x).reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        let values = vProj(x).reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        let offset = cache?.offset ?? 0
        queries = rotate(queries, offset: offset)
        keys = rotate(keys, offset: offset)

        let attended = attentionWithCacheUpdate(
            queries: queries, keys: keys, values: values, cache: cache, scale: scale, mask: mask)
        // Per-head sigmoid gate on the attended values, [B, L, heads] -> [B, heads, L, 1].
        let gate = sigmoid(gateProj(x)).transposed(0, 2, 1)[.ellipsis, .newAxis]
        return oProj((attended * gate).transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

final class LFM3ShortConv: Module {
    let lCache: Int

    @ModuleInfo(key: "conv") var conv: Conv1d
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ args: LFM3Configuration) {
        lCache = args.convLCache
        _conv.wrappedValue = Conv1d(
            inputChannels: args.hiddenSize, outputChannels: args.hiddenSize,
            kernelSize: lCache, groups: args.hiddenSize, bias: args.convBias)
        _inProj.wrappedValue = Linear(args.hiddenSize, 3 * args.hiddenSize, bias: args.convBias)
        _outProj.wrappedValue = Linear(args.hiddenSize, args.hiddenSize, bias: args.convBias)
    }

    func callAsFunction(_ x: MLXArray, cache: MambaCache?) -> MLXArray {
        let parts = inProj(x).split(parts: 3, axis: -1)
        var gated = parts[0] * parts[2]

        // The causal window: the last `lCache - 1` inputs of the previous call, or zeros.
        let state = cache?[0] ?? MLXArray.zeros([gated.dim(0), lCache - 1, gated.dim(2)], dtype: gated.dtype)
        gated = concatenated([state, gated], axis: -2)
        if let cache {
            cache[0] = contiguous(gated[0..., (gated.dim(1) - (lCache - 1))..., 0...])
            cache.advance(x.dim(1))
        }
        return outProj(parts[1] * conv(gated))
    }
}

final class LFM3MLP: Module, UnaryLayer {
    @ModuleInfo(key: "w1") var w1: Linear
    @ModuleInfo(key: "w2") var w2: Linear
    @ModuleInfo(key: "w3") var w3: Linear

    init(_ args: LFM3Configuration) {
        _w1.wrappedValue = Linear(args.hiddenSize, args.intermediateSize, bias: false)
        _w2.wrappedValue = Linear(args.intermediateSize, args.hiddenSize, bias: false)
        _w3.wrappedValue = Linear(args.hiddenSize, args.intermediateSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        w2(silu(w1(x)) * w3(x))
    }
}

final class LFM3DecoderLayer: Module {
    let layerType: LFM3Configuration.LayerType

    @ModuleInfo(key: "self_attn") var attention: LFM3Attention?
    @ModuleInfo(key: "conv") var conv: LFM3ShortConv?
    @ModuleInfo(key: "feed_forward") var feedForward: LFM3MLP
    @ModuleInfo(key: "operator_norm") var operatorNorm: RMSNorm
    @ModuleInfo(key: "ffn_norm") var ffnNorm: RMSNorm
    @ModuleInfo(key: "post_operator_norm") var postOperatorNorm: RMSNorm?
    @ModuleInfo(key: "post_ffn_norm") var postFFNNorm: RMSNorm?

    init(_ args: LFM3Configuration, layerType: LFM3Configuration.LayerType) {
        self.layerType = layerType
        switch layerType {
        case .conv: _conv.wrappedValue = LFM3ShortConv(args)
        case .fullAttention: _attention.wrappedValue = LFM3Attention(args, rope: args.fullAttentionRope)
        case .slidingAttention: _attention.wrappedValue = LFM3Attention(args, rope: args.slidingAttentionRope)
        }
        _feedForward.wrappedValue = LFM3MLP(args)
        _operatorNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.normEps)
        _ffnNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.normEps)
        if args.useSandwichNorm {
            _postOperatorNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.normEps)
            _postFFNNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.normEps)
        }
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let normed = operatorNorm(x)
        var operatorOutput = if let attention {
            attention(normed, mask: mask, cache: cache)
        } else {
            conv!(normed, cache: cache as? MambaCache)
        }
        if let postOperatorNorm { operatorOutput = postOperatorNorm(operatorOutput) }
        let h = x + operatorOutput

        var ffnOutput = feedForward(ffnNorm(h))
        if let postFFNNorm { ffnOutput = postFFNNorm(ffnOutput) }
        return h + ffnOutput
    }
}

final class LFM3ModelInner: Module {
    let args: LFM3Configuration

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "embedding_norm") var embeddingNorm: RMSNorm
    let layers: [LFM3DecoderLayer]

    init(_ args: LFM3Configuration) {
        self.args = args
        _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        _embeddingNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.normEps)
        layers = args.layerTypes.map { LFM3DecoderLayer(args, layerType: $0) }
    }

    /// Sliding layers keep the full KV history, so the window is enforced by the mask alone.
    /// A key is visible when it is at most `window - 1` positions behind its query.
    static func slidingMask(length n: Int, offset: Int, window: Int) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if offset == 0 && n <= window { return n == 1 ? .none : .causal }
        if n == 1 && offset + 1 <= window { return .none }
        return .array(createCausalMask(n: n, offset: offset, windowSize: window))
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedTokens(inputs)
        let types = args.layerTypes
        let n = h.dim(1)

        func cacheOfFirst(_ type: LFM3Configuration.LayerType) -> KVCache? {
            guard let cache, let index = types.firstIndex(of: type), index < cache.count else { return nil }
            return cache[index]
        }
        let fullMask = createAttentionMask(h: h, cache: cacheOfFirst(.fullAttention))
        let slidingMask = Self.slidingMask(
            length: n, offset: cacheOfFirst(.slidingAttention)?.offset ?? 0, window: args.slidingWindow)

        for (index, layer) in layers.enumerated() {
            let mask = layer.layerType == .slidingAttention ? slidingMask : fullMask
            h = layer(h, mask: mask, cache: cache?[index])
        }
        return embeddingNorm(h)
    }
}

final class LFM3Model: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]
    let model: LFM3ModelInner
    let configuration: LFM3Configuration

    init(_ args: LFM3Configuration) {
        configuration = args
        vocabularySize = args.vocabularySize
        kvHeads = args.layerTypes.map { $0.isAttention ? args.kvHeads : 0 }
        model = LFM3ModelInner(args)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        model.embedTokens.asLinear(model(inputs, cache: cache))
    }

    /// Converts a PyTorch-layout depthwise conv weight ([out, 1, kernel]) to MLX's [out, kernel, 1].
    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = weights
        for (name, weight) in weights where name.hasSuffix("conv.conv.weight") && weight.ndim == 3 {
            if weight.dim(2) > weight.dim(1) { sanitized[name] = weight.transposed(0, 2, 1) }
        }
        return sanitized
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try configuration.layerTypes.map { type in
            switch type {
            case .conv: MambaCache()
            case .fullAttention: try makeAttentionKVCache(parameters: parameters)
            case .slidingAttention: KVCacheSimple()
            }
        }
    }
}

extension LFM3Model: LoRAModel {
    var loraLayers: [Module] { model.layers }
}

extension LFM3Model {
    /// The `lfm3` model type, for a factory that is not the shared one: mlx-swift-lm has no LFM3.
    static var typeRegistry: ModelTypeRegistry<LanguageModel> {
        ModelTypeRegistry<LanguageModel>(creators: ["lfm3": { data in
            LFM3Model(try JSONDecoder().decode(LFM3Configuration.self, from: data))
        }])
    }
}
