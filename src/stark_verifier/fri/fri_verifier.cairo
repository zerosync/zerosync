from starkware.cairo.common.cairo_builtins import BitwiseBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero, horner_eval, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.pow import pow
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.hash_state import hash_finalize, hash_init, hash_update
from starkware.cairo.common.registers import get_fp_and_pc

from stark_verifier.air.air_instance import AirInstance, G, TWO_ADICITY
from stark_verifier.air.stark_proof import ProofOptions
from stark_verifier.crypto.random import PublicCoin, reseed, draw, reseed_endian, contains, hash_elements
from stark_verifier.fri.utils import evaluate_polynomial, lagrange_eval
from utils.pow2 import pow2
from stark_verifier.channel import Channel, verify_merkle_proof, QueriesProof, read_remainder
from crypto.hash_utils import assert_hashes_equal

const TWO_ADIC_ROOT_OF_UNITY = G;
const MULTIPLICATIVE_GENERATOR = 3;

struct FriOptions {
    folding_factor: felt,
    max_remainder_size: felt,
    blowup_factor: felt,
}

func to_fri_options(proof_options: ProofOptions) -> FriOptions {
    let folding_factor = proof_options.fri_folding_factor;
    let max_remainder_size = proof_options.fri_max_remainder_size;
    let fri_options = FriOptions(
        folding_factor,
        max_remainder_size,
        proof_options.blowup_factor
    );
    return fri_options;
}

struct FriVerifier {
    max_poly_degree: felt,
    domain_size: felt,
    domain_generator: felt,
    layer_commitments: felt*,
    layer_alphas: felt*,
    options: FriOptions,
}

func _fri_verifier_new{
    range_check_ptr,
    blake2s_ptr: felt*,
    bitwise_ptr: BitwiseBuiltin*,
    public_coin: PublicCoin,
}(
    options: FriOptions,
    max_degree_plus_1,
    layer_commitment_ptr: felt*,
    layer_alpha_ptr: felt*,
    count: felt,
) {
    if (count == 0) {
        return ();
    }
    alloc_locals;

    reseed_endian(layer_commitment_ptr);
    let alpha = draw();
    assert [layer_alpha_ptr] = alpha;

    _fri_verifier_new(
        options,
        max_degree_plus_1 / options.folding_factor,
        layer_commitment_ptr + 8,
        layer_alpha_ptr + 1,
        count - 1
    );
    return ();
}

func fri_verifier_new{
    range_check_ptr,
    blake2s_ptr: felt*,
    bitwise_ptr: BitwiseBuiltin*,
    public_coin: PublicCoin,
    channel: Channel
}(
    options: FriOptions,
    max_poly_degree
) -> FriVerifier {

    alloc_locals;

    let _next_power_of_two = next_power_of_two(max_poly_degree);
    let domain_size = _next_power_of_two * options.blowup_factor;

    let domain_size_log2 = log2(domain_size);
    let domain_generator = get_root_of_unity(domain_size_log2);
    // air.trace_domain_generator ?
    // air.lde_domain_generator ?

    // read layer commitments from the channel and use them to build a list of alphas
    let (layer_alphas) = alloc();
    let layer_commitments = channel.fri_roots;
    _fri_verifier_new(
        options,
        max_poly_degree + 1,
        layer_commitments,
        layer_alphas,
        channel.fri_roots_len
    );

    let res = FriVerifier(
        max_poly_degree,
        domain_size,
        domain_generator,
        layer_commitments,
        layer_alphas,
        options,
    );
    return res;
}

func next_power_of_two{range_check_ptr}(x) -> felt {
    alloc_locals;
    local n_bits;
    %{
        ids.n_bits = len( bin(ids.x - 1).replace('0b', '') )
    %}
    local next_power_of_two = pow2(n_bits);
    local x2_1 = x*2-1;
    with_attr error_message("{x} <= {next_power_of_two} <= {x2_1}") {
        assert_le(x, next_power_of_two);
        assert_le(next_power_of_two, x * 2 - 1);
    }
    return next_power_of_two;
}

func get_root_of_unity{range_check_ptr}(n) -> felt {
    with_attr error_message("cannot get root of unity for n = 0") {
        assert_not_zero(n);
    }
    with_attr error_message("order cannot exceed 2^{TWO_ADICITY}") {
        assert_le(n, TWO_ADICITY);
    }
    let power = pow2(TWO_ADICITY - n);
    let (root_of_unity) = pow(TWO_ADIC_ROOT_OF_UNITY, power);
    return root_of_unity;
}

func log2(n) -> felt {
    alloc_locals;
    local n_bits;
    %{
        ids.n_bits = len( bin(ids.n - 1).replace('0b', '') )
    %}
    let next_power_of_two = pow2(n_bits);
    with_attr error_message("n must be a power of two") {
        assert next_power_of_two = n;
    }
    return n_bits;
}


func fri_verify{
    range_check_ptr, pedersen_ptr: HashBuiltin*, blake2s_ptr: felt*, channel: Channel, bitwise_ptr: BitwiseBuiltin*
    }(fri_verifier: FriVerifier, evaluations: felt*, positions: felt*
) {
    alloc_locals;
    let num_queries = 54;
    // Read FRI Merkle proofs from a hint
    let merkle_proofs = read_fri_proofs(positions);

    // Verify a round for each query
    let (__fp__, _) = get_fp_and_pc();
    // ----- TODO: remove this HACK. This works only for a single layer
    let modulus = fri_verifier.domain_size / fri_verifier.options.folding_factor;
    let (folded_positions) = alloc();
    let num_queries = fold_positions(positions, folded_positions, num_queries, 0, modulus);
    // -----
    verify_queries(&fri_verifier, folded_positions, evaluations, num_queries, merkle_proofs.queries_proofs, merkle_proofs.query_values);

    // Check that a Merkle tree of the claimed remainders hash to the final layer commitment
    let remainder = read_remainder();

    // Ensure that the interpolated remainder polynomial is of degree <= max_remainder_degree
    verify_remainder_degree(
        remainders=remainder.elements,
        remainders_len=remainder.n_elements,
        max_degree=fri_verifier.options.max_remainder_size
    );

    return ();
}

struct FriQueriesProof{
    queries_proofs: QueriesProof*,
    query_values: felt*,
}

func verify_queries{
    range_check_ptr, 
    channel: Channel, 
    blake2s_ptr:felt*,
    bitwise_ptr: BitwiseBuiltin*
}(
    fri_verifier: FriVerifier*,
    positions: felt*,
    query_evaluations: felt*,
    num_queries: felt,
    queries_proofs: QueriesProof*,
    query_values: felt*
) {
    if (num_queries == 0) {
        return ();
    }
    alloc_locals;
    
    let num_layers = num_fri_layers(fri_verifier, fri_verifier.domain_size); 
    let folding_factor = fri_verifier.options.folding_factor;
    let num_layer_evaluations = folding_factor * num_layers;
    let log_degree = log2(fri_verifier.domain_size);
    let alphas = fri_verifier.layer_alphas;

    let position = [positions];

    // Compute the field element coordinate at the queried position
    // g: domain offset
    // omega: domain generator
    // x: omega^position * g
    let g = MULTIPLICATIVE_GENERATOR;
    let omega = fri_verifier.domain_generator;
    let (omega_i) = pow(omega, position);

    // Compute the remaining folded roots of unity
    let (omega_folded) = alloc();
    compute_folded_roots(omega_folded, omega, log_degree, folding_factor, 1);


    %{ print(f'verify_queries  -  num_queries: {ids.num_queries}, domain_size: {ids.fri_verifier.domain_size}, folding_factor: {ids.folding_factor}') %}

    let modulus = fri_verifier.domain_size / folding_factor;

    // Iterate over the layers within this query
    verify_layers(
        g,
        omega_i,
        alphas,
        position,
        query_evaluations,
        num_layer_evaluations,
        num_layers,
        folding_factor,
        0,
        queries_proofs,
        query_values,
        modulus
    );

    // TODO: Check that the claimed remainder is equal to the final evaluation.

    // Iterate over the remaining queries
    verify_queries(
        fri_verifier,
        &positions[1],
        &query_evaluations[1],
        num_queries - 1,
        &queries_proofs[1],
        &query_values[folding_factor],
    );
    return ();
}

func num_fri_layers{
        range_check_ptr
    }(fri_verifier: FriVerifier*, domain_size) -> felt{
    let is_leq = is_le(fri_verifier.options.max_remainder_size, domain_size);
    if(is_leq == 0){
        return 0;
    }
    let res = num_fri_layers(fri_verifier, domain_size/fri_verifier.options.folding_factor);
    return 1 + res;
}

func compute_folded_roots{
    range_check_ptr
    }(omega_folded: felt*, omega, log_degree: felt, folding_factor: felt, n: felt) {
    if (n == folding_factor) {
        return ();
    }
    let (degree) = pow(2, log_degree);
    let new_domain_size = degree / folding_factor * n;
    let (res) = pow(omega, new_domain_size);
    assert [omega_folded] = res;
    compute_folded_roots(omega_folded + 1, omega, log_degree, folding_factor, n + 1);
    return ();
}

func verify_layers{
    range_check_ptr, 
    channel: Channel, 
    blake2s_ptr: felt*,
    bitwise_ptr: BitwiseBuiltin*
}(
    g: felt,
    omega_i: felt,
    alphas: felt*,
    position: felt,
    query_evaluations_raw: felt*,
    num_layer_evaluations: felt,
    num_layers: felt,
    folding_factor: felt,
    previous_eval: felt,
    queries_proof: QueriesProof*,
    query_values: felt*,
    modulus: felt
) {
    if (num_layers == 0) {
        return ();
    }
    alloc_locals;
    %{ print(f'verify_layers  -  num_layers: {ids.num_layers}, num_layer_evaluations: {ids.num_layer_evaluations},  position: {ids.position}, modulus: {ids.modulus}') %}

    let alpha = [alphas];
    let x = g * omega_i;

    // Swap the evaluation points if the folded point is in the second half of the domain
    let (local query_evaluations) = alloc();
    swap_evaluation_points(query_evaluations, query_evaluations_raw, num_layer_evaluations);

    // Verify that evaluations are consistent with the layer commitment
    let (_, folded_position) = unsigned_div_rem(position, modulus);
    verify_merkle_proof(queries_proof.length, queries_proof.digests, position, channel.fri_roots);
    let leaf_hash = hash_elements(n_elements=folding_factor, elements=query_values);
    assert_hashes_equal(leaf_hash, queries_proof.digests);                                                                                                                                                        
    let is_contained = contains([query_evaluations], query_values, folding_factor);
    assert_not_zero(is_contained);

    // TODO: Compare previous polynomial evaluation with the current layer evaluation
    if (previous_eval != 0) {
        assert previous_eval = [query_evaluations + 1];
    }
    // Interpolate the evaluations at the x-coordinates, and evaluate at alpha.
    let eval = evaluate_polynomial(query_evaluations, num_layer_evaluations, folding_factor, alpha);
    let previous_eval = eval;

    // Update variables for the next layer
    let (omega_i) = pow(omega_i, folding_factor);
    let modulus = modulus / folding_factor;

    verify_layers(
        g,
        omega_i,
        alphas + 1,
        folded_position,
        query_evaluations_raw + 1,
        num_layer_evaluations,
        num_layers - 1,
        folding_factor,
        previous_eval,
        queries_proof, // TODO: jump to next layer here
        query_values, // TODO: jump to next layer here
        modulus
    );

    return ();
}


func swap_evaluation_points(query_evaluations: felt*, query_evaluations_raw: felt*, num_layer_evaluations) {
    // TODO: Swap the evaluation points if the folded point is in the second half of the domain
    memcpy(query_evaluations, query_evaluations_raw, num_layer_evaluations);
    return ();
}

func verify_remainder_degree{range_check_ptr, pedersen_ptr: HashBuiltin*}(
    remainders: felt*, remainders_len: felt, max_degree: felt
) {
    alloc_locals;
    let (remainders_poly) = alloc(); // TODO: interpolate this from `remainders`
    // Use the commitment to the remainder polynomial and evaluations to draw a random
    // field element tau
    let (hash_state_ptr) = hash_init();
    let (hash_state_ptr) = hash_update{hash_ptr=pedersen_ptr}(
        hash_state_ptr=hash_state_ptr,
        data_ptr=remainders,
        data_length=remainders_len
    );
    // let (hash_state_ptr) = hash_update{hash_ptr=pedersen_ptr}(
    //     hash_state_ptr=hash_state_ptr,
    //     data_ptr=remainders_poly,
    //     data_length=remainders_len
    // );
    // let (tau) = hash_finalize{hash_ptr=pedersen_ptr}(hash_state_ptr=hash_state_ptr);

    // Roots of unity for remainder evaluation domain
    let k = log2(remainders_len);
    let omega_n = get_root_of_unity(k);
    let (omega_i) = alloc();
    get_roots_of_unity(omega_i, omega_n, 0, remainders_len);

    // Evaluate both polynomial representations at tau and confirm agreement
    // let (a) = horner_eval(max_degree, remainders_poly, tau);
    // let (b) = lagrange_eval(remainder_evaluations, omega_i, remainders_len, tau);
    // assert a = b;

    // TODO: Check that all polynomial coefficients greater than 'max_degree' are zero

    return ();
}

func get_roots_of_unity{range_check_ptr}(omega_i: felt*, omega_n: felt, i: felt, len: felt) {
    if (i == len) {
        return ();
    }
    let (x) = pow(omega_n, i);
    assert [omega_i] = x;
    get_roots_of_unity(omega_i + 1, omega_n, i + 1, len);
    return ();
}


func read_fri_proofs {
    range_check_ptr, blake2s_ptr: felt*, channel: Channel, bitwise_ptr: BitwiseBuiltin*
    }(positions: felt*) -> FriQueriesProof* {
    alloc_locals;

    let num_queries = 54;
    let (local fri_queries_proof_ptr: FriQueriesProof*) = alloc();
    %{
        import json
        import subprocess
        from src.stark_verifier.utils import write_into_memory

        layer_index = "0"
        positions = []
        for i in range(ids.num_queries):
            positions.append( memory[ids.positions + i] )

        positions = json.dumps( positions )

        completed_process = subprocess.run([
            'bin/stark_parser',
            'tests/integration/stark_proofs/fibonacci.bin', # TODO: this path shouldn't be hardcoded here!
            'fri-queries',
            positions
            ],
            capture_output=True)
        
        json_data = completed_process.stdout
        write_into_memory(ids.fri_queries_proof_ptr, json_data, segments)
    %}

    return fri_queries_proof_ptr;
}

func fold_positions{
    range_check_ptr
}(positions: felt*, next_positions: felt*, loop_counter, elems_count, modulus) -> felt {
    if (loop_counter == 0){
        return elems_count;
    }
    alloc_locals;
    let prev_position = [positions];
    let (_, next_position) = unsigned_div_rem(prev_position, modulus);
    // make sure we don't record duplicated values
    let is_contained = contains(next_position, next_positions - elems_count, elems_count);
    if(is_contained == 1){
        return fold_positions(positions + 1, next_positions, loop_counter - 1, elems_count, modulus);
    } else {
        assert next_positions[0] = next_position;
        return fold_positions(positions + 1, next_positions + 1, loop_counter - 1, elems_count + 1, modulus);
    }
}
