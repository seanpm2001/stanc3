functions {
  matrix covar_fun (vector x, real alpha) {
    matrix[1, 1] covariance;
    return covariance;
  }
}

transformed data {
 array[1] int y;
 array[1]  int n_samples;
 vector[1] theta0;
 vector[1] x;
 real tol = 1e-3;  // CHECK -- what should this be.
 int max_num_steps = 1000;
 int hessian_block_size = 2;
 int solver = 2;  // CHECK
 int max_steps_line_search = 3;
}

parameters {
  real alpha;
}

model {
  
  target +=
    laplace_marginal_poisson_log_tol_lpmf(y | n_samples, tol, max_num_steps,
                                  hessian_block_size,
                                  solver, max_steps_line_search, theta0, covar_fun, x, alpha);
  y ~ laplace_marginal_poisson_log(n_samples, theta0, covar_fun, x, alpha);
  
}
/*
generated quantities {
   vector[1] y_pred = laplace_marginal_poisson_log_rng(y, n_samples, theta0, 
     covar_fun, forward_as_tuple(x), forward_as_tuple(x), alpha);
}
*/