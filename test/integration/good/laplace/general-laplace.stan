
functions {
    matrix K_f(vector phi, matrix x, vector delta, int[] delta_int) {
      int n_patients = delta_int[1];
      vector[2 * n_patients] K_vec;
      return diag_matrix(K_vec);
    }

    real L_f(vector theta, vector eta, vector delta, int[] delta_int) {
    return 1.0;
  }
}


data {
  int N;
  vector[N] y_obs;
  vector[N] time;
  int n_patients;
  array[n_patients] int<lower = 1, upper = N> start;
  array[n_patients] int<lower = 1, upper = N> end;
  real<lower = 0> y0;  // initial dose.
}

transformed data {
  matrix[0, 0] x_mat_dummy;
  vector[2 * n_patients] theta0 = rep_vector(0, 2 * n_patients);
  real tol = 1e-3;  // CHECK -- what should this be.
  int max_num_steps = 1000;
  int hessian_block_size = 2;
  int solver = 2;  // CHECK
  array[2 * n_patients + 4] int delta_int;
  vector[2 * N + 1] delta;

  delta_int[1] = n_patients;
  delta_int[2] = N;
  delta_int[3:(n_patients + 2)] = start;
  delta_int[(n_patients + 3):(2 * n_patients + 2)] = end;

  delta[1:N] = y_obs;
  delta[(N + 1):(2 * N)] = time;
  delta[2 * N + 1] = y0;
  int max_steps_line_search = 100;

}

parameters {
  real<lower = 0> sigma;
  real<lower = 0> sigma_0;
  real<lower = 0> sigma_1;
  real k_0_pop;
  real k_1_pop;
  vector[2] phi;
  vector[3] eta;
  // vector[n_patients] k_0;
  // vector[n_patients] k_1;
}

transformed parameters {
}

model {

  // likelihood
  target += laplace_marginal_tol_lpdf(delta | L_f, eta, delta_int,
                                  tol, max_num_steps,
                                  hessian_block_size,
                                  solver, max_steps_line_search, theta0, K_f,
                                  phi, x_mat_dummy, to_vector(delta), delta_int);
}

generated quantities {
    /*
  vector[2 * n_patients] theta_pred = laplace_marginal_tol_rng(L_f, eta, delta, delta_int,
                                                   K_f, phi, x_mat_dummy,
                                                  to_array_1d(delta), delta_int,
                                                   theta0,
                                                   tol, max_num_steps,
                                                   hessian_block_size,
                                                   solver);
  */
  // vector[n_patients] k_0;
  // vector[n_patients] k_1;
  //
  // for (i in 1:n_patients) {
  //   k_0[i] = k_0_pop + theta_pred[1 + 2 * (i - 1)];
  //   k_1[i] = k_1_pop + theta_pred[2 * i];
  // }
}
