//! Grappa client tokens for the `com.apple.atc` authorization check.
//!
//! The device advertises `GrappaSupportInfo { version, deviceType, protocolVersion }`
//! in its `Capabilities` message. The host must echo a matching client token in
//! `HostInfo` / `RequestingSync`, or the sync is silently ignored.
//!
//! Upstream (AirCard-iOS `GrappaHelper.m`) generates these by calling Apple's
//! `ATGrappaSession` on macOS and, on iOS, falls back to a hardcoded table of
//! pre-generated tokens for `deviceType = 0`. We reuse that table — no Apple
//! framework needed. See `docs/airtraffic-protocol.md` §5.5.

/// Pre-generated authentic tokens for (version = 1, deviceType = 0, protocolVersion = 1).
const TOKENS_HEX: [&str; 10] = [
    "01012ba6a01f2ccf66a02613d5b72e0bc916004058a001a6874d18b5bd7b3395e25d79fa3ffcc67e718106d485c51540b828d1620e9f94f582d3bcc6f97e9088c923095ad8d36ab568fb45df61e286d25354b04c",
    "0101efa33b1586f410087474b2ccaf8cdb4d0040e5aee6017fdcf774a51c1980b4238076e86218af5a5f169470df90b73f4fc893a22da94fb9745c10f23df0620cfe3f19be3f2ab37d2f7590d8597ab51ebcced0",
    "0101aab479a6d8226f3e1d7a57a2501337e50240e54444b5f1d04101205a7a2f3d148d18440e2edef03d37fcdc7423c0bb441b4c4a355169d511d67ae3466fdf8865e69a8aed45867801ea8e1bbb48889ba0b834",
    "010194ab2ece86e05d7313e4075a947ab3be0240c9237c46b3c519d2ec297304413dab741827016e5eb9af8792bc2b3d6f12be25397931f41bffb887d042b97057c03ed8d72a3acb72378d30f7a073e3d7590f62",
    "01018cec0ea2c25446c90133d435eaafb0150240c6c28dd42f62f8907133c462fc8b6def05e543ab2d59952f6eb3b38e382d492cd2881beceaeaea67fc1331f77fca50fde6bed35622009670e6d6e4a36b09c088",
    "0101243b2587f14dd812751c6710730f46d50440fe2e5e9ccfe70200487e14c131412381fd7c214241b182ca04ebe0c1f3cdd54ac17eef31705c06289e02f672fa8c0d9dff167f1c925df876d5814d3265f55b06",
    "01016f8908f8f972bdc8fe99002f7648e86c024011a469c4320bb7e44137756dde3ecfbff08a55081e532c12a06101c6ae5283a014512d977eafad06c34b1f116422f6bf72ef56f8d734d37db287b170be7a3a82",
    "01015c5fcc103d0460f5bbfd48c387806e8e0340e3323ed780fbeccc2908c059d9a81e75976bf058b411f62a9a6e1df7ba307f69226942373f484690799b230bc60e99036f40eae25229aff6bb31ab74820e68a9",
    "0101f3f542aaa17252a8f81b3dc5b007adc304408d2496cee3af54113ffa9fba392b4143d4c38e4d79680e8e9feb554e450c1f89220c02375a9063b3a62bf61f62bd073991ebf215c6c2e28938d1aa53ed580c02",
    "0101fc26f7e89d1635d86b5c886df69f526a0040038b6c33049f6bd5cc526b4ee7ccce614135d2c73f8326d9af6d28399a231510917493d4fdaa395b4d1c1e1b09bdf3fe6fb7e16ad6d5f5cc18b93730874e6f4e",
];

/// Decode the token at `index` (clamped into range).
pub fn token(index: usize) -> Vec<u8> {
    let hex = TOKENS_HEX[index.min(TOKENS_HEX.len() - 1)];
    hex_bytes(hex)
}

fn hex_bytes(hex: &str) -> Vec<u8> {
    hex.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let s = std::str::from_utf8(pair).expect("hex is ascii");
            u8::from_str_radix(s, 16).expect("valid hex")
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_decode_to_expected_length() {
        // Every published token is the same size; the Python probe saw 84 bytes.
        for i in 0..TOKENS_HEX.len() {
            assert_eq!(token(i).len(), 84, "token {i} length");
        }
    }

    #[test]
    fn out_of_range_index_clamps() {
        assert_eq!(token(999), token(TOKENS_HEX.len() - 1));
    }
}
