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
}

parameters {
  real alpha;
}

model {
  target += laplace_marginal_poisson_log_lpmf(y | n_samples, theta0, covar_fun, alpha, alpha);
}

