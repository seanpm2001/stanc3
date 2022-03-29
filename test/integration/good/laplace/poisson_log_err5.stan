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


model {
  
  y ~ laplace_marginal_poisson_log(n_samples, theta0, covar_fun);

}

