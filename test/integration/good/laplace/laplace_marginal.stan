functions {
  matrix K_f (vector phi, matrix x, real[] delta, int[] delta_int) {
    matrix[1, 1] covariance;
    return covariance;
  }
  
  real L_f (vector theta, vector eta, vector delta, int[] delta_int) {
    real lk;
    return lk;
  }
}

transformed data {
  vector[1] delta_L;
  int delta_int_L[1];

  vector[1] phi;
  vector[1] eta;
  matrix[1, 1] x;
  real delta_K[1];
  int delta_int_K[1];

  vector[1] theta0;
  real tol;
  int max_num_steps;
  int hessian_block_size;
  int compute_W_root;
}

parameters {
  vector[1] phi_v;
  vector[1] eta_v;
  vector[1] theta0_v;
}

model {
  // lpdf signatures
  target += laplace_marginal_lpdf(delta_L | L_f, eta, delta_int_L, 
                                  K_f, phi, x, delta_K, delta_int_K,
                                  theta0, tol, max_num_steps,
                                  hessian_block_size, compute_W_root);
  
  target += laplace_marginal_lpdf(delta_L | L_f, eta_v, delta_int_L,
                                  K_f, phi_v, x, delta_K, delta_int_K,
                                  theta0, tol, max_num_steps,
                                  hessian_block_size, compute_W_root);

  // lpmf signatures
  target += laplace_marginal_lpmf(delta_int_L | L_f, eta, delta_L, 
                                  K_f, phi, x, delta_K, delta_int_K,
                                  theta0, tol, max_num_steps,
                                  hessian_block_size, compute_W_root);

  target += laplace_marginal_lpmf(delta_int_L | L_f, eta_v, delta_L, 
                                  K_f, phi_v, x, delta_K, delta_int_K,
                                  theta0, tol, max_num_steps,
                                  hessian_block_size, compute_W_root);
}

generated quantities {
  vector[1] theta_pred = laplace_rng(L_f, eta, delta_L, delta_int_L,
                                  K_f, phi, x, delta_K, delta_int_K,
                                  theta0, tol, max_num_steps,
                                  hessian_block_size, compute_W_root);

  theta_pred = laplace_rng(L_f, eta_v, delta_L, delta_int_L,
                           K_f, phi_v, x, delta_K, delta_int_K,
                           theta0, tol, max_num_steps,
                           hessian_block_size, compute_W_root);
}
