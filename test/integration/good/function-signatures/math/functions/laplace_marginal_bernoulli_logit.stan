functions {
  matrix K(vector phi, array[] vector x, array[] real delta,
           array[] int delta_int) {
    matrix[1, 1] covariance;
    return covariance;
  }
  
  matrix Km(vector phi, matrix x, array[] real delta, array[] int delta_int) {
    matrix[1, 1] covariance;
    return covariance;
  }
}
transformed data {
  array[1] int y;
  array[1] int n_samples;
  
  vector[1] phi;
  array[1] vector[1] x;
  matrix[1, 1] x_m;
  array[1] real delta;
  array[1] int delta_int;
  
  vector[1] theta0;
}
parameters {
  vector[1] phi_v;
  vector[1] theta0_v;
}

model {
  target +=
    laplace_marginal_bernoulli_logit_lpmf(y | n_samples, theta0, K, phi, x, delta,
                                          delta_int);
  target +=
    laplace_marginal_bernoulli_logit_lpmf(y | n_samples, theta0, Km, phi, x_m, delta,
                                          delta_int);
}

generated quantities {
  vector[1] theta_pred
    = laplace_bernoulli_logit_rng(y, n_samples, theta0, K, phi, x, delta, delta_int);
  theta_pred = laplace_bernoulli_logit_rng(y, n_samples, theta0, Km, phi, x_m, delta,
                                            delta_int);
}

