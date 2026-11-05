//! CPU baseline for dag-sigverify.
//! Builds N packets shaped like Solana transactions (1 signature over a ~176 byte message),
//! corrupts a known share of them, then verifies them three ways and checks every result:
//!   1. one core, one signature at a time (what a naive validator thread does)
//!   2. all cores, one signature at a time (rayon)
//!   3. all cores, ed25519-dalek batch verification in chunks of 64
//! Prints a JSON line with signatures per second for each mode.
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::{rngs::OsRng, Rng};
use rayon::prelude::*;
use std::time::Instant;

struct Pkt { pk: VerifyingKey, msg: Vec<u8>, sig: Signature, valid: bool }

fn make(n: usize, bad_every: usize) -> Vec<Pkt> {
    let keys: Vec<SigningKey> = (0..256).map(|_| SigningKey::generate(&mut OsRng)).collect();
    (0..n).into_par_iter().map(|i| {
        let k = &keys[i % keys.len()];
        let mut msg = vec![0u8; 176];
        rand::thread_rng().fill(&mut msg[..]);
        let sig = k.sign(&msg);
        let valid = bad_every == 0 || i % bad_every != 0;
        if !valid { msg[0] ^= 1; } // tamper after signing: must be rejected
        Pkt { pk: k.verifying_key(), msg, sig, valid }
    }).collect()
}

fn rate(n: usize, f: impl FnOnce() -> usize) -> (f64, usize) {
    let t = Instant::now(); let ok = f(); let s = t.elapsed().as_secs_f64(); (n as f64 / s, ok)
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(200_000);
    let bad_every = 100; // 1% invalid
    let p = make(n, bad_every);
    let expect = p.iter().filter(|x| x.valid).count();

    let one = n.min(50_000);
    let (r1, ok1) = rate(one, || p[..one].iter().filter(|x| x.pk.verify(&x.msg, &x.sig).is_ok()).count());
    let exp1 = p[..one].iter().filter(|x| x.valid).count();
    let (r2, ok2) = rate(n, || p.par_iter().filter(|x| x.pk.verify(&x.msg, &x.sig).is_ok()).count());
    // batch: a chunk passes or fails as a whole; failed chunks fall back to single checks (like a real verifier)
    let (r3, ok3) = rate(n, || p.par_chunks(64).map(|c| {
        let msgs: Vec<&[u8]> = c.iter().map(|x| x.msg.as_slice()).collect();
        let sigs: Vec<Signature> = c.iter().map(|x| x.sig).collect();
        let pks: Vec<VerifyingKey> = c.iter().map(|x| x.pk).collect();
        if ed25519_dalek::verify_batch(&msgs, &sigs, &pks).is_ok() { c.len() } else { c.iter().filter(|x| x.pk.verify(&x.msg, &x.sig).is_ok()).count() }
    }).sum());
    let correct = ok1 == exp1 && ok2 == expect && ok3 == expect;
    println!("{}", serde_json::json!({
        "device": "cpu", "threads": rayon::current_num_threads(), "signatures": n, "invalid_share": 1.0 / bad_every as f64,
        "single_core_sigs_per_s": r1.round(), "all_cores_sigs_per_s": r2.round(), "all_cores_batch64_sigs_per_s": r3.round(),
        "results_correct": correct
    }));
    if !correct { eprintln!("MISMATCH: {ok1}/{exp1} {ok2}/{expect} {ok3}/{expect}"); std::process::exit(1); }
}
