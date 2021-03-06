# TODO: ensure that sd is correct for all models
# TODO: better names for columns/functions
# TODO: Check namespaces

library(tidyverse)
devtools::load_all()
settings = yaml::yaml.load_file("settings.yaml")

if (!file.exists("observer_model.rds")) {
  fit_observer_model()
}
obs_model = readRDS("observer_model.rds")

# Discard unnecessary data to save memory
bioclim_to_discard = colnames(obs_model$data) %>% 
  grep("^bio", ., value = TRUE) %>% 
  discard(~.x %in% settings$vars) 

# `c()` is needed for a few lines because of distinction between
# vectors and 1D arrays
x_richness = obs_model$data %>% 
  mutate(intercept = c(obs_model$intercept[iteration]), 
         sd = c(obs_model$sigma[iteration]),
         expected_richness = richness - observer_effect) %>% 
  select(-ndvi_ann, -lat, -long, -site_index, -one_of(bioclim_to_discard))

# Reclaim memory
rm(obs_model)
gc()


# Fit & save models --------------------------------------------------------

# "Average" model with observer effects
x_richness %>% 
  filter(!in_train) %>% 
  mutate(mean = intercept + observer_effect + site_effect,
         model = "average", use_obs_model = TRUE) %>% 
  select(site_id, year, mean, sd, iteration, richness, model, use_obs_model) %>% 
  saveRDS(file = "avg_TRUE.rds")

# "Average" model without observer effects
# Use site-level means and sds from the training set as test-set predictions
x_richness %>% 
  filter(in_train) %>% 
  group_by(site_id) %>% 
  summarize(mean = mean(richness), sd = sd(richness), model = "average", 
            use_obs_model = FALSE) %>% 
  left_join(select(x_richness, -sd), "site_id") %>% 
  filter(!in_train) %>% 
  select(site_id, year, mean, sd, richness, model, use_obs_model) %>% 
  saveRDS(file = "avg_FALSE.rds")


# Forecast-based predictions
# For all combinations of forecast function & use_obs_model (TRUE/FALSE)
# run make_forecasts with data & settings.
expand.grid(fun_name = c("naive", "auto.arima"), 
            use_obs_model = c(TRUE, FALSE),
            stringsAsFactors = FALSE) %>% 
  transpose() %>% 
  parallel::mclapply(
    function(grid_row){
      do.call(make_all_forecasts, 
             c(x = list(x_richness), settings = list(settings), grid_row))
    },
    mc.cores = 8, 
    mc.preschedule = FALSE
  ) %>% 
  bind_rows() %>% 
  saveRDS(file = "forecast.rds")

# GBM richness with observer effects:
x_richness %>%
  group_by(iteration) %>%
  by_slice(make_gbm_predictions, use_obs_model = TRUE, .collate = "rows") %>% 
  saveRDS(file = "gbm_TRUE.rds")

# GBM richness without observer effects:
# Don't need to group/by_slice because only fitting one iteration
x_richness %>%
  filter(iteration == 1) %>%
  make_gbm_predictions(use_obs_model = FALSE) %>% 
  saveRDS(file = "gbm_FALSE.rds")


# fit random forest SDMs -------------------------------------------------------

# Get data on individual species occurrences
bbs = get_pop_ts_env_data(settings$start_yr, 
                          settings$end_yr, 
                          settings$min_num_yrs) %>% 
  filter(!is.na(abundance))

# Discard species that don't occur in the training set
bbs = bbs %>% 
  filter(year <= settings$last_train_year) %>% 
  distinct(species_id) %>% 
  left_join(bbs)

dir.create("rf_predictions", showWarnings = FALSE)

gc() # Minimize memory detritus before forking

rf_sdm_obs = rf_predict_richness(bbs = bbs, x_richness = x_richness, 
                                 settings = settings, use_obs_model = TRUE,
                                 mc.cores = 8) %>% 
  saveRDS(file = "rf_predictions/all_TRUE.rds")

rf_sdm_no_obs = rf_predict_richness(bbs = bbs, x_richness = x_richness, 
                                    settings = settings, use_obs_model = FALSE,
                                    mc.cores = 8) %>% 
  saveRDS(file = "rf_predictions/all_FALSE.rds")
