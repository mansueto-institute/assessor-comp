# Load packages -----------------------------------------------------------

library(tidyverse)
library(DBI)
library(curl)
library(ptaxsim)
library(ccao)
library(assessr)
library(viridis)
library(arrow)
library(duckdb)
library(sf)
library(sfarrow)
library(patchwork)
library(scales)
library(nlme)

# Based on code here: https://uchicago.app.box.com/folder/219001753953?tc=collab-folder-invite-treatment-b

# -------------------------------------------------------------------------

# Methodological questions
# https://docs.google.com/presentation/d/14OiOJM22-s2ggyydYCqhhO8BWVGHUvbYs9vRljP1qDA/edit#slide=id.p

# 1) Should we restrict comparisons to each area's triennial assessment year?
#    So compare the city in 2018 to 2021, northern subs in 2016 to 2019, southern subs in 2017 to 2020?
# 2) Should we make comparisons between the previous years (t-1) sales and current years (t) assessment?
#    The argument for doing this is b/c the current year model's training data goes up to Dec 31 of the previous year,
#    so for instance the 2023 model is based on 2022 sales up to Dec 31. On the other hand, comparing
#    2022 sales vs 2022 model provides insight into how well the model forecasts, and it eliminates the possibility of sales chasing,
#    and bias from using in sample training data (if they are not producing out of sample scores for data included in the training data).
# 3) Should exclude condos from the study (apparently they use a different assessment model and Berrios used to sales chase)?
#    "Regression classes" are technically the only PINs that are subject to the automated valuation model.
#    If we do include condos, both 299 + 399 are subject to the condo model, which we should compare separately.
#    And the 300 level multifamily as well as 400s, 500s, 600s, 700s etc are handled by commercial valuation team (assuming we exclude).

# Relevant repos
# https://ccao-data.github.io/ptaxsim/reference/index.html
# https://ccao-data.github.io/ccao/reference/index.html
# https://ccao-data.github.io/assessr/reference/index.html
# https://cmf-uchicago.github.io/cmfproperty/index.html
# https://github.com/cmf-uchicago/cmfproperty/

# -------------------------------------------------------------------------

# EDIT DIRECTORY PATH
# setwd("/Users/nm/Desktop/Projects/work/cook-assessor/download.nosync")

# dir.create("data", showWarnings = FALSE)

# -------------------------------------------------------------------------

# Data download ------------------------------------------------------------

## Parcel sales source: https://datacatalog.cookcountyil.gov/Property-Taxation/Assessor-Parcel-Sales/wvhk-k5uv
# curl::multi_download("https://datacatalog.cookcountyil.gov/api/views/wvhk-k5uv/rows.csv", "data/Assessor_-_Parcel_Sales.csv", resume = TRUE)
# parcel_sales <- read_csv("data/Assessor_-_Parcel_Sales.csv")
# write_parquet(parcel_sales, "data/Assessor_-_Parcel_Sales.parquet")
# rm(parcel_sales)

## Property tax and assessment download ------------------------------------
## Property tax bill database source: https://github.com/ccao-data/ptaxsim#ptaxsim
## Download link: https://ccao-data-public-us-east-1.s3.amazonaws.com/ptaxsim/ptaxsim-2021.0.4.db.bz2

# https://datacatalog.cookcountyil.gov/Property-Taxation/Assessor-Parcel-Universe/nj4t-kc8j
# z <- read_json_arrow('https://datacatalog.cookcountyil.gov/resource/nj4t-kc8j.json$select=pin, township_code')
# https://datacatalog.cookcountyil.gov/api/views/nj4t-kc8j/rows.csv


## BoR Appeals Data  ----------------------------------------------------------
# curl::multi_download("https://datacatalog.cookcountyil.gov/api/views/7pny-nedm/rows.csv", "data/BoR_-_Parcel_Appeals.csv", resume = TRUE)
# parcel_appeals <- read_csv("data/BoR_-_Parcel_Appeals.csv")
# write_parquet(parcel_appeals, "data/BoR_-_Parcel_Appeals.parquet")

# Import data -------------------------------------------------------------

# Sales
sales_data <- read_parquet("data/Assessor_-_Parcel_Sales.parquet") %>%
  filter(year >= 2011) %>%
  # select(pin, year, sale_date, sale_price) %>%
  select(-class, -township_code) %>%
  mutate(pin = str_pad(string = pin, width = 14, side = c("left"), pad = "0", use_width = TRUE))

# Remove least recent sales for properties that sold more than once in a year
sales_data <- sales_data %>%
  mutate(sale_date_posix = lubridate::parse_date_time(x = sale_date, orders = "%b %d %Y", exact = TRUE)) %>%
  group_by(pin, year) %>%
  mutate(repeat_sale_order = row_number(desc(sale_date_posix))) %>%
  ungroup() %>%
  filter(repeat_sale_order == 1)

# Property tax bills and assessments
ptaxsim_db_conn <- DBI::dbConnect(RSQLite::SQLite(), "/Users/divijsinha/Library/CloudStorage/Box-Box/Cook County 2023/ptaxsim-2021.0.4.db/ptaxsim-2021.0.4.db")
ptax_data <- dbGetQuery(ptaxsim_db_conn, "SELECT year, pin, tax_code_num, class, tax_bill_total, av_mailed, av_certified, av_board, av_clerk FROM pin where year >= 2011") %>% as_tibble()


# class_data <- read_csv('https://raw.githubusercontent.com/ccao-data/ccao/master/data-raw/class_dict.csv')
# Source: https://prodassets.cookcountyassessor.com/s3fs-public/form_documents/classcode.pdf
class_data <- ccao::class_dict

class_data <- class_data %>%
  mutate(res_nonres_label = case_when(
    major_class_type == "Residential" ~ "Residential",
    TRUE ~ "Non-residential"
  ))

# Limit class data to regression - residential unit types
class_data_regression_only <- class_data %>%
  filter(regression_class == TRUE) %>%
  select(reporting_group, class_code)

# Township data
# Source: https://datacatalog.cookcountyil.gov/GIS-Maps/Historical-ccgisdata-Political-Township-2016/uvx8-ftf4
townships <- ccao::town_shp %>% st_make_valid()

# PTAX summary

ptax_class_year_summary <- ptax_data %>%
  filter(year >= 2011 & year <= 2022) %>%
  inner_join(., class_data, by = c("class" = "class_code")) %>%
  group_by(year, major_class_type) %>%
  summarise(pin_total_count = n(), av_board_sum = sum(av_board)) %>%
  ungroup()

ptax_class_year_triad_summary <- ptax_data %>%
  filter(year >= 2011 & year <= 2022) %>%
  inner_join(., class_data, by = c("class" = "class_code")) %>%
  mutate(township_code = str_sub(tax_code_num, start = 1L, end = 2L)) %>%
  left_join(
    .,
    townships %>% st_drop_geometry() %>% select(township_code, triad_name),
    join_by(township_code == township_code)
  ) %>%
  group_by(year, major_class_type, triad_name) %>%
  summarise(pin_total_count = n(), av_board_sum = sum(av_board)) %>%
  ungroup()

# Appeals
parcel_appeals <- read_parquet("data/BoR_-_Parcel_Appeals.parquet") %>%
  filter(tax_year >= 2011) %>%
  filter(Class != 0)

# THIS SHOULD ALWAYS BE EMPTY
# parcel_appeals %>% filter((Class >= 1000) & (Class <= 9999))

parcel_appeals <- parcel_appeals %>%
  mutate(class_char = ifelse(Class >= 1000, Class / 100, Class)) %>%
  mutate(class_char = as.character(class_char)) %>%
  inner_join(., class_data, join_by(class_char == class_code))

appeals_summary <- parcel_appeals %>%
  group_by(tax_year, major_class_type, Result) %>%
  summarise(
    count = n(),
    assessor_total = sum(Assessor_TotalValue),
    bor_total = sum(BOR_TotalValue)
  ) %>%
  ungroup() %>%
  full_join(
    ., ptax_class_year_summary, join_by(tax_year == year, major_class_type)
  ) %>%
  mutate(ratio = count / pin_total_count)

appeals_summary_by_triad <- parcel_appeals %>%
  mutate(township_code = as.character(township_code)) %>%
  left_join(
    .,
    townships %>% st_drop_geometry() %>% select(township_code, triad_name),
    join_by(township_code == township_code)
  ) %>%
  group_by(tax_year, major_class_type, Result, triad_name) %>%
  summarise(
    count = n(),
    assessor_total = sum(Assessor_TotalValue),
    bor_total = sum(BOR_TotalValue)
  ) %>%
  ungroup() %>%
  full_join(
    .,
    ptax_class_year_triad_summary,
    join_by(tax_year == year, major_class_type, triad_name)
  ) %>%
  mutate(ratio = count / pin_total_count)


# Join class, township, and sales data to assessments ---------------------

# Join in class data, township data, filter years for sales ratio analysis
sales_ptax <- ptax_data %>%
  filter(year >= 2011 & year <= 2022) %>%
  inner_join(., class_data_regression_only, by = c("class" = "class_code")) %>%
  mutate(township_code = str_sub(tax_code_num, start = 1L, end = 2L)) %>%
  left_join(., townships %>% st_drop_geometry() %>% select(township_code, triad_name), by = c("township_code" = "township_code")) %>%
  mutate(pin = str_pad(string = pin, width = 14, side = c("left"), pad = "0", use_width = TRUE))

# Join sales data to property tax data
sales_ptax <- sales_ptax %>%
  inner_join(., sales_data, by = c("pin" = "pin", "year" = "year"))

# No nulls check
sapply(sales_ptax, function(X) sum(is.na(X)))

# Calculate ratios -------------------------------------------------------

sales_ptax <- sales_ptax %>%
  mutate(
    av_ratio_mailed = av_mailed / sale_price,
    av_ratio_certified = av_certified / sale_price,
    av_ratio_board = av_board / sale_price,
    av_ratio_clerk = av_clerk / sale_price
  )

# Flag outliers -----------------------------------------------------------

# Outlier rule according to IAAO standards (1.5 X IQR procedure to identify outlier ratios)
# https://www.iaao.org/media/standards/Standard_on_Ratio_Studies.pdf#page=54
sales_ptax <- sales_ptax %>%
  group_by(year, township_code, class) %>%
  mutate(
    quartile_1 = quantile(x = av_ratio_mailed, 1 / 4),
    quartile_3 = quantile(x = av_ratio_mailed, 3 / 4),
    iqr = quartile_3 - quartile_1,
    lower_trim_point = quartile_1 - (iqr * 1.5),
    upper_trim_point = quartile_3 + (iqr * 1.5)
  ) %>%
  ungroup() %>%
  mutate(outlier_flag_iaao = case_when(av_ratio_mailed > lower_trim_point & av_ratio_mailed < upper_trim_point ~ 1, TRUE ~ as.integer(0))) %>%
  group_by(year, township_code, class) %>%
  mutate(
    av_ratio_1_to_99 = case_when(av_ratio_mailed < quantile(av_ratio_mailed, 0.01) | av_ratio_mailed > quantile(av_ratio_mailed, 0.99) ~ 0, TRUE ~ as.integer(1)),
    av_ratio_2_to_98 = case_when(av_ratio_mailed < quantile(av_ratio_mailed, 0.02) | av_ratio_mailed > quantile(av_ratio_mailed, 0.98) ~ 0, TRUE ~ as.integer(1)),
    av_ratio_3_to_97 = case_when(av_ratio_mailed < quantile(av_ratio_mailed, 0.03) | av_ratio_mailed > quantile(av_ratio_mailed, 0.97) ~ 0, TRUE ~ as.integer(1)),
    av_ratio_4_to_96 = case_when(av_ratio_mailed < quantile(av_ratio_mailed, 0.04) | av_ratio_mailed > quantile(av_ratio_mailed, 0.96) ~ 0, TRUE ~ as.integer(1)),
    av_ratio_5_to_95 = case_when(av_ratio_mailed < quantile(av_ratio_mailed, 0.05) | av_ratio_mailed > quantile(av_ratio_mailed, 0.95) ~ 0, TRUE ~ as.integer(1))
  ) %>%
  ungroup() %>%
  select(-one_of(c("quartile_1", "quartile_3", "iqr", "lower_trim_point", "upper_trim_point")))


# CPI ---------------------------------------------------------------------

# Housing in Midwest urban, all urban consumers, not seasonally adjusted
# BLS Series ID: CUUS0200SAH
housing_cpi_2023 <- list(
  year = c(2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022, 2023),
  cpi = c(1.337313638, 1.311831482, 1.287789597, 1.27184103, 1.240585497, 1.214959196, 1.182246279, 1.153904209, 1.13468867, 1.068232043, 1)
) %>%
  as.data.frame()

# S&P/Case-Shiller U.S. National Home Price Index
# https://fred.stlouisfed.org/series/CSUSHPINSA#0
case_shiller_2023 <- list(
  year = c(2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022, 2023),
  case_shiller = c(1.663090915, 1.695792557, 1.859953584, 2.054125555, 2.109306578, 2.191465155, 2.164322318, 1.974783404, 1.852951133, 1.772351191, 1.686676152, 1.594359191, 1.507122687, 1.456873311, 1.373748227, 1.173319935, 1.022240399, 1)
) %>%
  as.data.frame()

# FHFA HPI Expanded-Data Index (Estimated using Enterprise, FHA, and Real Property County Recorder Data Licensed from DataQuick for sales below the annual loan limit ceiling)
# https://www.fhfa.gov/DataTools/Downloads/Pages/House-Price-Index-Datasets.aspx#qexe

hpi_2023 <- list(
  year = c(2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022, 2023),
  hpi = c(1.14407178, 1.174738966, 1.376691816, 1.66707653, 1.797687182, 1.96643901, 2.015771149, 1.87304141, 1.755724941, 1.674818614, 1.572943284, 1.47916753, 1.403425097, 1.354186158, 1.266441223, 1.142716924, 1.027848684, 1)
) %>%
  as.data.frame()

sales_ptax <- sales_ptax %>%
  left_join(., housing_cpi_2023, by = c("year" = "year")) %>%
  left_join(., case_shiller_2023, by = c("year" = "year")) %>%
  left_join(., hpi_2023, by = c("year" = "year"))

sales_ptax <- sales_ptax %>%
  mutate(across(all_of(c("tax_bill_total", "sale_price", "av_mailed", "av_certified", "av_board", "av_clerk")), ~ .x * cpi, .names = "{.col}_cpi"),
    across(all_of(c("tax_bill_total", "sale_price", "av_mailed", "av_certified", "av_board", "av_clerk")), ~ .x * case_shiller, .names = "{.col}_case_shiller"),
    across(all_of(c("tax_bill_total", "sale_price", "av_mailed", "av_certified", "av_board", "av_clerk")), ~ .x * hpi, .names = "{.col}_hpi"),
    effective_tax_rate = tax_bill_total / sale_price
  )

# Comparison groups -------------------------------------------------------

sales_ptax <- sales_ptax %>%
  filter(reporting_group != "Bed & Breakfast") %>%
  mutate(
    assessor_term = case_when(
      year <= 2010 & year >= 1998 ~ "Houlihan",
      year <= 2018 & year >= 2011 ~ "Berrios",
      year <= 2024 & year >= 2019 ~ "Kaegi"
    ),
    comparison_years = case_when(
      year == 2018 | year == 2021 ~ "2018 vs. 2021", # city
      year == 2017 | year == 2020 ~ "2017 vs. 2020", # south
      year == 2016 | year == 2019 ~ "2016 vs. 2019", # north
      TRUE ~ as.character("Before 2015")
    ),
    assessor_term_year = paste0(assessor_term, " ", year),
    reporting_group = factor(reporting_group, levels = c("Single-Family", "Multi-Family", "Condominium"))
  )

# FLAGGING SALES OUTLIERS ---------------------------------------------------

sales_ptax <- sales_ptax %>%
  group_by(reporting_group) %>%
  mutate(
    mean_log10_sale = mean(log10(sale_price_hpi)),
    sd_log10_sale = sd(log10(sale_price_hpi)),
    lower_sale_threshold = mean_log10_sale - 3 * sd_log10_sale,
    upper_sale_threshold = mean_log10_sale + 3 * sd_log10_sale,
    sale_price_outlier = ifelse(log10(sale_price_hpi) > lower_sale_threshold & log10(sale_price_hpi) < upper_sale_threshold, 1, 0)
  )

# Captions for later use ---------------------------------------------------

caption_1 <- paste0(
  "Note: Points represent averages summarized by sales percentile, property type, triad, and year. Points are scaled to the number of sales. Ratios more than 1.5 times the lower or upper\n",
  "interquartile range were excluded. Sale prices are inflation adjusted to 2023 dollars using the FHFA HPI. The above comparison only covers residential sales taking place in years for which its\n",
  "township underwent a re-assessment (e.g., 2018 or 2021 for the City, 2016 or 2019 for the North suburbs, and 2017 or 2020 for the South suburbs). Tax bills for a certain year are payable in\n",
  "the next year. The tax-bills sent out in the first year of a new administration, were partially or in whole subject to the methods of assessment of the older administration. \n",
  "Class codes: Single Family - 202, 203, 204, 205, 206, 207, 208, 209, 210, 234, 278, 295. Multi Family - 212, 213. Condominumium - 299, 399."
)

caption_2 <- paste0(
  "Note: Tax bills for a certain year are payable in the next year. The tax-bills sent out in the first year of a new administration, were partially or in whole subject to the methods of\n",
  "assessment of the older administration. Residential refers to all properties in the 200s class. Commercial refers to all properties with the class 500, 501, 516, 517, 522, 523, 526, \n",
  "527, 528, 529, 530, 531, 532, 533, 535, 590, 591, 592, 597, 599. For more information: https://prodassets.cookcountyassessor.com/s3fs-public/form_documents/classcode.pdf."
)

caption_3 <- paste0(
  "Note: Tax bills for a certain year are payable in the next year. The tax-bills sent out in the first year of a new administration, were partially or in whole subject to the methods of assessment\n",
  "of the older administration. Only including class codes: Single Family - 202, 203, 204, 205, 206, 207, 208, 209, 210, 234, 278, 295. Multi Family - 212, 213. Condos - 299, 399. Within\n",
  "each reporting group, excludes sales more than 3 standard deviations away from the mean, in the log prices."
)

caption_4 <- paste0(
  "Note: Tax bills for a certain year are payable in the next year. The tax-bills sent out in the first year of a new administration, were partially or in whole subject to the methods of\n",
  "assessment of the older administration. The above data reflects reductions in assessed values among residential properties sold the same year for which they were re-assessed.\n",
  "Points are scaled to the number of sales. Data with assessed value ratios more than 1.5 times the lower or upper interquartile range were excluded. Sale prices are inflation\n",
  "adjusted to 2023 dollars using the FHFA HPI."
)

# Visualizations ----------------------------------------------------------

# Cook county sales ratio -------------------------------------------------

sales_ptax_summary <- sales_ptax %>%
  filter(
    outlier_flag_iaao == 1,
    year >= 2016
  ) %>%
  filter((triad_name == "City" & comparison_years == "2018 vs. 2021") |
    (triad_name == "North" & comparison_years == "2016 vs. 2019") |
    (triad_name == "South" & comparison_years == "2017 vs. 2020")) %>%
  group_by(year, reporting_group) %>%
  mutate(sales_ntile = ntile(x = sale_price_hpi, n = 100)) %>%
  ungroup() %>%
  mutate(count = 1) %>%
  group_by(
    sales_ntile, reporting_group,
    comparison_years, assessor_term, assessor_term_year
  ) %>%
  summarize(
    count = sum(count),
    av_ratio_mailed = mean(av_ratio_mailed),
    sale_price = mean(sale_price),
    sale_price_cpi = mean(sale_price_cpi),
    sale_price_hpi = mean(sale_price_hpi)
  ) %>%
  ungroup()

# Cook by property type (CPI)
(cook_comp_av <- ggplot(
  data = sales_ptax_summary,
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term, fill = assessor_term, color = assessor_term
  )
) +
  facet_wrap(~reporting_group) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .1, aes(size = count)) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  scale_y_continuous(name = "Assessed value to sale price ratio", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "Cook County"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

(cook_comp_av_total <- ggplot(
  data = sales_ptax_summary,
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term, fill = assessor_term, color = assessor_term
  )
) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .1, aes(size = count)) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  scale_y_continuous(name = "", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "Cook County Total"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15),
    axis.line.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank()
  ))

(cook_comp_av_w_total <- cook_comp_av + cook_comp_av_total +
  plot_layout(ncol = 2, guides = "collect", widths = c(3, 1)) +
  plot_annotation(caption = caption_1) &
  theme(legend.position = "bottom", plot.caption = element_text(size = 12, hjust = 0), )
)

(cook_comp_av <- cook_comp_av + labs(caption = caption_1))


# Sales ratio charts by triad ------------------------------------------------

sales_ptax_summary <- sales_ptax %>%
  filter(
    outlier_flag_iaao == 1,
    year >= 2016
  ) %>%
  group_by(year, triad_name, reporting_group) %>%
  mutate(sales_ntile = ntile(x = sale_price_hpi, n = 100)) %>%
  ungroup() %>%
  mutate(count = 1) %>%
  group_by(
    sales_ntile, reporting_group, triad_name,
    comparison_years, assessor_term, assessor_term_year
  ) %>%
  summarize(
    count = sum(count),
    av_ratio_mailed = mean(av_ratio_mailed),
    sale_price = mean(sale_price),
    sale_price_cpi = mean(sale_price_cpi),
    sale_price_hpi = mean(sale_price_hpi)
  ) %>%
  ungroup()

# City by property type (CPI)
(city_comp_av <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "City" & comparison_years == "2018 vs. 2021"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  facet_wrap(~reporting_group) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "Assessed value to sale price ratio", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "City of Chicago"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

(city_comp_av_total <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "City" & comparison_years == "2018 vs. 2021"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "City of Chicago"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15),
    axis.line.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank()
  ))


(city_comp_av_w_total <- city_comp_av + city_comp_av_total +
  plot_layout(ncol = 2, guides = "collect", widths = c(3, 1)) +
  plot_annotation(caption = caption_1) &
  theme(legend.position = "bottom", plot.caption = element_text(size = 12, hjust = 0), )
)

(city_comp_av <- city_comp_av + labs(caption = caption_1))


# North suburbs by property type (CPI)
(north_comp_av <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "North" & comparison_years == "2016 vs. 2019"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  facet_wrap(~reporting_group) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "Assessed value to sale price ratio", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "North suburbs"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

(north_comp_av_total <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "North" & comparison_years == "2016 vs. 2019"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "North suburbs"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15),
    axis.line.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank()
  ))


(north_comp_av_w_total <- north_comp_av + north_comp_av_total +
  plot_layout(ncol = 2, guides = "collect", widths = c(3, 1)) +
  plot_annotation(caption = caption_1) &
  theme(legend.position = "bottom", plot.caption = element_text(size = 12, hjust = 0), )
)

(north_comp_av <- north_comp_av + labs(caption = caption_1))

# South suburbs by property type (CPI)
(south_comp_av <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "South" & comparison_years == "2017 vs. 2020"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  facet_wrap(~reporting_group) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "Assessed value to sale price ratio", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "South suburbs"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

(south_comp_av_total <- ggplot(
  data = sales_ptax_summary %>% filter(triad_name == "South" & comparison_years == "2017 vs. 2020"),
  aes(
    x = sale_price_hpi, y = av_ratio_mailed,
    group = assessor_term_year, fill = assessor_term_year, color = assessor_term_year
  )
) +
  geom_hline(yintercept = .1, color = "grey", alpha = .8, linetype = 2) +
  geom_point(alpha = .2, aes(size = count)) +
  scale_color_manual(values = c("#66c2a5", "#8da0cb")) +
  geom_smooth(method = "loess", formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "", limits = c(0, .3), expand = c(0, 0)) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(0, 3), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  labs(
    subtitle = "South suburbs"
  ) +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 15, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, hjust = 0),
    legend.key.width = unit(40, "pt"),
    legend.position = "bottom", legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15),
    axis.line.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank()
  ))


(south_comp_av_w_total <- south_comp_av + south_comp_av_total +
  plot_layout(ncol = 2, guides = "collect", widths = c(3, 1)) +
  plot_annotation(caption = caption_1) &
  theme(legend.position = "bottom", plot.caption = element_text(size = 12, hjust = 0), )
)

(south_comp_av <- south_comp_av + labs(caption = caption_1))


# Residential pre/post Board of Review ------------------------------------

sales_ptax_summary <- sales_ptax %>%
  filter(outlier_flag_iaao == 1, year >= 2019) %>%
  group_by(year) %>%
  mutate(sales_ntile = ntile(x = sale_price_cpi, n = 100)) %>%
  ungroup() %>%
  mutate(count = 1) %>%
  group_by(year, sales_ntile, assessor_term) %>%
  summarize(
    count = sum(count),
    av_mailed_cpi = mean(av_mailed_cpi),
    av_board_cpi = mean(av_board_cpi),
    av_mailed_hpi = mean(av_mailed_hpi),
    av_board_hpi = mean(av_board_hpi),
    av_ratio_mailed = mean(av_ratio_mailed),
    av_ratio_board = mean(av_ratio_board),
    sale_price = mean(sale_price),
    sale_price_cpi = mean(sale_price_cpi),
    sale_price_hpi = mean(sale_price_hpi),
  ) %>%
  ungroup() %>%
  mutate(
    assessed_value_board_mailed_ratio = av_board_cpi / av_mailed_cpi,
    assessed_value_board_mailed_diff = av_board_cpi - av_mailed_cpi,
    assessed_value_board_mailed_diff_pct = assessed_value_board_mailed_diff / av_mailed_cpi
  ) %>%
  pivot_longer(cols = c(av_mailed_cpi, av_board_cpi, av_mailed_hpi, av_board_hpi, av_ratio_mailed, av_ratio_board, assessed_value_board_mailed_ratio, assessed_value_board_mailed_diff, assessed_value_board_mailed_diff_pct)) %>%
  mutate(name_label = case_when(
    name == "count" ~ "Count",
    name == "av_mailed_cpi" ~ "Assessed value (mailed), CPI",
    name == "av_board_cpi" ~ "Assessed value (Board of Review), CPI",
    name == "av_mailed_hpi" ~ "Assessed value (mailed), HPI",
    name == "av_board_hpi" ~ "Assessed value (Board of Review), HPI",
    name == "av_ratio_mailed" ~ "Assessed value ratio (mailed)",
    name == "av_ratio_board" ~ "Assessed value ratio (Board of Review)",
    name == "sale_price_cpi" ~ "Sale price, CPI",
    name == "sale_price_hpi" ~ "Sale price, HPI",
    name == "assessed_value_board_mailed_ratio" ~ "Board of Review assessment relative to mailed assessment",
    name == "assessed_value_board_mailed_diff" ~ "Reduction in assessed value after Board of Review appeal",
    name == "assessed_value_board_mailed_diff_pct" ~ "Percent change in assessed value after Board of Review appeal"
  ))

# Cook County Board of Review pre/post
(bor_pre_post_chart <- ggplot(
  data = sales_ptax_summary %>% filter(name == "assessed_value_board_mailed_diff"),
  aes(
    x = sale_price_hpi, y = value,
    group = as.character(year), fill = as.character(year), color = as.character(year)
  )
) +
  geom_point(alpha = .2, aes(size = count)) +
  geom_smooth(method = "loess", span = 1, formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "Reduction in assessed value", limits = c(-15000, 10), label = scales::dollar_format()) +
  scale_x_continuous(
    name = "Sale price", expand = c(0, 20), limits = c(0, 1000000),
    breaks = c(0, 250000, 500000, 750000, 1000000),
    labels = c("", "$250K", "$500K", "$750K", "$1M")
  ) +
  scale_size_binned(name = "Number of sales", range = c(1, 4), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  scale_color_manual(values = c("#49DEA4", "#ffc425", "#fc8d62")) +
  labs(subtitle = "", caption = "") +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 12, hjust = .5, color = "#333333"),
    plot.caption = element_text(size = 12),
    # legend.position = 'bottom',
    legend.key.width = unit(40, "pt"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 11, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ) +
  ggplot(
    data = sales_ptax_summary %>% filter(name == "assessed_value_board_mailed_diff_pct"),
    aes(
      x = sale_price_hpi, y = value,
      group = as.character(year), fill = as.character(year), color = as.character(year)
    )
  ) +
  geom_point(alpha = .2, aes(size = count)) +
  geom_smooth(method = "loess", span = 1, formula = "y ~ x", aes(weight = count), se = FALSE) +
  scale_y_continuous(name = "Percent change in assessed value", limits = c(-.2, 0), label = scales::percent_format()) +
  scale_x_continuous(name = "Sale price", expand = c(0, 20), limits = c(0, 1000000), breaks = c(0, 250000, 500000, 750000, 1000000), labels = c("", "$250K", "$500K", "$750K", "$1M")) +
  scale_size_binned(name = "Number of sales", range = c(1, 4), n.breaks = 3, breaks = waiver(), labels = comma_format()) +
  scale_color_manual(values = c("#49DEA4", "#ffc425", "#fc8d62")) +
  labs(subtitle = "") +
  theme_classic() +
  theme(
    plot.subtitle = element_text(size = 12, hjust = .5, color = "#333333"),
    plot.caption = element_text(size = 12),
    # legend.position = 'bottom',
    legend.key.width = unit(40, "pt"),
    legend.text = element_text(size = 13, color = "#333333"), legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 11, color = "#333333"),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ) +
  plot_annotation(
    title = "Change in assessed value of residential properties after Board of Review appeal",
    caption = caption_4
  ) +
  plot_layout(ncol = 2, guides = "collect") &
  theme(
    legend.position = "bottom",
    plot.caption = element_text(size = 12, hjust = 0),
    plot.title = element_text(hjust = .5, color = "#333333", face = "bold", size = 13)
  ))

# Composition commercial v residential ------------------------------------

ptax_data_composition_abs <- ptax_data %>%
  filter(year >= 2011 & year <= 2022) %>%
  inner_join(., class_data, by = c("class" = "class_code")) %>%
  mutate(township_code = str_sub(tax_code_num, start = 1L, end = 2L)) %>%
  left_join(
    .,
    townships %>% st_drop_geometry() %>% select(township_code, triad_name),
    by = c("township_code" = "township_code")
  ) %>%
  mutate(pin = str_pad(string = pin, width = 14, side = c("left"), pad = "0", use_width = TRUE)) %>%
  group_by(major_class_type, year) %>%
  summarize_at(vars(c("tax_bill_total", "av_mailed", "av_certified", "av_board", "av_clerk")), list(sum)) %>%
  ungroup() %>%
  select(major_class_type, year, av_mailed, av_board, av_certified, av_clerk, tax_bill_total) %>%
  pivot_longer(cols = c(av_mailed, av_board, av_certified, av_clerk, tax_bill_total)) %>%
  mutate(name = case_when(
    name == "tax_bill_total" ~ "Tax bills",
    name == "av_board" ~ "Assessed value (Board of Review)",
    name == "av_certified" ~ "Assessed value (certified)",
    name == "av_clerk" ~ "Assessed value (Clerk)",
    name == "av_mailed" ~ "Assessed value (mailed)"
  )) %>%
  filter(name %in% c("Tax bills", "Assessed value (Board of Review)", "Assessed value (mailed)")) %>%
  mutate(name = factor(name, levels = c("Assessed value (mailed)", "Assessed value (Board of Review)", "Tax bills")))


ptax_data_composition <- ptax_data %>%
  filter(year >= 2011 & year <= 2022) %>%
  inner_join(., class_data, by = c("class" = "class_code")) %>%
  mutate(township_code = str_sub(tax_code_num, start = 1L, end = 2L)) %>%
  left_join(
    .,
    townships %>% st_drop_geometry() %>% select(township_code, triad_name),
    by = c("township_code" = "township_code")
  ) %>%
  mutate(pin = str_pad(string = pin, width = 14, side = c("left"), pad = "0", use_width = TRUE)) %>%
  group_by(major_class_type, year) %>%
  summarize_at(vars(c("tax_bill_total", "av_mailed", "av_certified", "av_board", "av_clerk")), list(sum)) %>%
  ungroup() %>%
  group_by(year) %>%
  mutate(
    av_mailed_sum = sum(av_mailed),
    av_board_sum = sum(av_board),
    av_certified_sum = sum(av_certified),
    av_clerk_sum = sum(av_clerk),
    tax_bill_total_sum = sum(tax_bill_total)
  ) %>%
  ungroup() %>%
  mutate(
    av_mailed_share = av_mailed / av_mailed_sum,
    av_board_share = av_board / av_board_sum,
    av_certified_share = av_certified / av_certified_sum,
    av_clerk_share = av_clerk / av_clerk_sum,
    tax_bill_share = tax_bill_total / tax_bill_total_sum
  ) %>%
  select(major_class_type, year, av_mailed_share, av_board_share, av_certified_share, av_clerk_share, tax_bill_share) %>%
  pivot_longer(cols = c(av_mailed_share, av_board_share, av_certified_share, av_clerk_share, tax_bill_share)) %>%
  mutate(name = case_when(
    name == "tax_bill_share" ~ "Tax bills",
    name == "av_board_share" ~ "Assessed value (Board of Review)",
    name == "av_certified_share" ~ "Assessed value (certified)",
    name == "av_clerk_share" ~ "Assessed value (Clerk)",
    name == "av_mailed_share" ~ "Assessed value (mailed)"
  )) %>%
  filter(name %in% c("Tax bills", "Assessed value (Board of Review)", "Assessed value (mailed)")) %>%
  mutate(name = factor(name, levels = c("Assessed value (mailed)", "Assessed value (Board of Review)", "Tax bills")))

(res_composition_chart <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = .4, ymax = .7), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = .4, ymax = .7), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = .4, ymax = .7), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = .45, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = .45, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = .45, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_point(
    data = ptax_data_composition %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, color = name), size = 12, alpha = .9
  ) +
  geom_line(
    data = ptax_data_composition %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, color = name), linewidth = 2, alpha = .3
  ) +
  geom_text(
    data = ptax_data_composition %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, label = paste0(round(value * 100), "%")),
    size = 4, fontface = "bold", color = "white",
    check_overlap = TRUE
  ) +
  scale_color_manual(values = c("#009EFA", "#845EC2", "#FF6F91")) +
  scale_y_continuous(name = "Residential share", limits = c(.4, .7), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Residential share of assessed property value and tax burden",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

(res_composition_chart_abs <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 1e9, ymax = 4.5e10), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 1e9, ymax = 4.5e10), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 1e9, ymax = 4.5e10), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 2e10, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = 2e10, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = 2e10, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_point(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, color = name), size = 12, alpha = .9
  ) +
  geom_line(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, color = name), linewidth = 2, alpha = .3
  ) +
  geom_text(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Residential"),
    aes(x = year, y = value, label = paste0("$", signif(value / 1e9, 2), "B")),
    size = 3.2, fontface = "bold", color = "white",
    check_overlap = TRUE
  ) +
  scale_color_manual(values = c("#009EFA", "#845EC2", "#FF6F91")) +
  scale_y_continuous(name = "Residential properties", limits = c(1e9, 4.5e10), expand = c(0, 0), labels = scales::label_dollar(scale_cut = cut_short_scale())) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Residential assessed property value and tax burden",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

(com_composition_chart <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = .23, ymax = .35), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = .23, ymax = .35), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = .23, ymax = .35), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = .25, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = .25, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = .25, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_point(
    data = ptax_data_composition %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, color = name), size = 12, alpha = .9
  ) +
  geom_line(
    data = ptax_data_composition %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, color = name), linewidth = 2, alpha = .3
  ) +
  geom_text(
    data = ptax_data_composition %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, label = paste0(round(value * 100), "%")),
    size = 4, fontface = "bold", color = "white",
    check_overlap = TRUE
  ) +
  scale_color_manual(values = c("#009EFA", "#845EC2", "#FF6F91")) +
  scale_y_continuous(name = "Commercial share", limits = c(.23, .35), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Commercial share of assessed property value and tax burden",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

(com_composition_chart_abs <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 3e10), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 3e10), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 3e10), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 8e9, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = 8e9, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = 8e9, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_point(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, color = name), size = 12, alpha = .9
  ) +
  geom_line(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, color = name), linewidth = 2, alpha = .3
  ) +
  geom_text(
    data = ptax_data_composition_abs %>% filter(major_class_type == "Commercial"),
    aes(x = year, y = value, label = paste0("$", signif(value / 1e9, 2), "B")),
    size = 3.2, fontface = "bold", color = "white",
    check_overlap = TRUE
  ) +
  scale_color_manual(values = c("#009EFA", "#845EC2", "#FF6F91")) +
  scale_y_continuous(name = "Commercial properties", limits = c(0, 3e10), expand = c(0, 0), labels = scales::label_dollar(scale_cut = cut_short_scale())) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Commercial assessed property value and tax burden",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

# Cook County Board of Review - ratio of reviews

(res_appeal_ratio_chart <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 0.45), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 0.45), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 0.45), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.35, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = 0.35, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = 0.35, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_area(
    data = appeals_summary %>% filter(major_class_type == "Residential", Result != "Increase"),
    aes(x = tax_year, y = ratio, fill = Result)
  ) +
  scale_fill_manual(values = c("#BFFBFF", "#00C7F8", "#CE5741")) +
  scale_y_continuous(name = "Ratio of residential properties", limits = c(0, 0.45), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Percentage of Residential properties with appeals filed to Board of Review, and outcomes",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

(com_appeal_ratio_chart <- ggplot() +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 0.75), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 0.75), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 0.75), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.7, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2016.5, y = 0.7, label = "Assessed under\nBerrios"), fontface = "bold") +
  geom_text(aes(x = 2020.5, y = 0.7, label = "Assessed under\nKaegi"), fontface = "bold") +
  geom_area(
    data = appeals_summary %>% filter(major_class_type == "Commercial", Result != "Increase"),
    aes(x = tax_year, y = ratio, fill = Result)
  ) +
  scale_fill_manual(values = c("#BFFBFF", "#00C7F8", "#CE5741")) +
  scale_y_continuous(name = "Ratio of commercial properties", limits = c(0, 0.75), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Percentage of Commercial properties with appeals filed to Board of Review, and outcomes",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank()
  ))

year_triad <- tibble(
  year = 2011:2022,
  triad_name = rep(c("South", "City", "North"), 4)
) %>%
  filter(year != 2022)

# Cook County Board of Review - ratio of reviews - by triad
(res_appeal_triad_ratio_chart <- ggplot(
  data = appeals_summary_by_triad %>% filter(major_class_type == "Residential", Result != "Increase"),
  aes(x = tax_year, y = ratio, fill = Result)
) +
  facet_wrap(~triad_name) +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 0.6), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 0.6), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 0.6), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.55, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2016.5, y = 0.55, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2020.5, y = 0.55, label = "Assessed under\nKaegi")) +
  geom_area() +
  scale_fill_manual(values = c("#BFFBFF", "#00C7F8")) +
  geom_vline(
    aes(xintercept = year, color = "Year of reassessment"),
    linetype = "longdash", alpha = 0.5, data = year_triad
  ) +
  facet_wrap(~triad_name) +
  scale_color_manual(values = c("#CE5741")) +
  scale_y_continuous(name = "Ratio of residential properties", limits = c(0, 0.6), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2013, 2015, 2017, 2019, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Percentage of Residential properties with appeals filed to Board of Review, and outcomes",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

(com_appeal_triad_ratio_chart <- ggplot(
  data = appeals_summary_by_triad %>% filter(major_class_type == "Commercial", Result != "Increase"),
  aes(x = tax_year, y = ratio, fill = Result)
) +
  facet_wrap(~triad_name) +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 0.95), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 0.95), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 0.95), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.9, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2016.5, y = 0.9, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2020.5, y = 0.9, label = "Assessed under\nKaegi")) +
  geom_area() +
  scale_fill_manual(values = c("#BFFBFF", "#00C7F8")) +
  geom_vline(
    aes(xintercept = year, color = "Year of reassessment"),
    linetype = "longdash", alpha = 0.5, data = year_triad
  ) +
  facet_wrap(~triad_name) +
  scale_color_manual(values = c("#CE5741")) +
  scale_y_continuous(name = "Ratio of commercial properties", limits = c(0, 0.95), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2013, 2015, 2017, 2019, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Percentage of Commercial properties with appeals filed to Board of Review, and outcomes",
    caption = caption_2
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

# -------------------------------------------------------------------------

# path_dir <- '/Users/nm/Desktop/Projects/work/cook-assessor/assessor-comp/Cook County 2023/viz'
path_dir <- "viz"

ggsave(plot = cook_comp_av, filename = paste0(path_dir, "/1-cook_av_ratio.pdf"), width = 15, height = 8)
ggsave(plot = cook_comp_av_w_total, filename = paste0(path_dir, "/1a-cook_av_w_total_ratio.pdf"), width = 15, height = 8)
ggsave(plot = city_comp_av, filename = paste0(path_dir, "/2-city_av_ratio.pdf"), width = 15, height = 8)
ggsave(plot = city_comp_av_w_total, filename = paste0(path_dir, "/2a-city_av_w_total_ratio.pdf"), width = 15, height = 8)
ggsave(plot = north_comp_av, filename = paste0(path_dir, "/3-north_av_ratio.pdf"), width = 15, height = 8)
ggsave(plot = north_comp_av_w_total, filename = paste0(path_dir, "/3a-north_av_w_total_ratio.pdf"), width = 15, height = 8)
ggsave(plot = south_comp_av, filename = paste0(path_dir, "/4-south_av_ratio.pdf"), width = 15, height = 8)
ggsave(plot = south_comp_av_w_total, filename = paste0(path_dir, "/4a-south_av_w_total_ratio.pdf"), width = 15, height = 8)
ggsave(plot = bor_pre_post_chart, filename = paste0(path_dir, "/5-bor_pre_post.pdf"), width = 14, height = 7)
ggsave(plot = res_composition_chart, filename = paste0(path_dir, "/6-res_composition.pdf"), width = 14, height = 7)
ggsave(plot = res_composition_chart_abs, filename = paste0(path_dir, "/6a-res_composition_abs.pdf"), width = 14, height = 7)
ggsave(plot = com_composition_chart, filename = paste0(path_dir, "/7-com_composition.pdf"), width = 14, height = 7)
ggsave(plot = com_composition_chart_abs, filename = paste0(path_dir, "/7a-com_composition_abs.pdf"), width = 14, height = 7)
ggsave(plot = res_appeal_ratio_chart, filename = paste0(path_dir, "/8-res_appeal_ratio.pdf"), width = 14, height = 7)
ggsave(plot = res_appeal_triad_ratio_chart, filename = paste0(path_dir, "/8a-res_appeal_ratio.pdf"), width = 14, height = 7)
ggsave(plot = com_appeal_ratio_chart, filename = paste0(path_dir, "/9-com_appeal_ratio.pdf"), width = 14, height = 7)
ggsave(plot = com_appeal_triad_ratio_chart, filename = paste0(path_dir, "/9a-com_appeal_ratio.pdf"), width = 14, height = 7)


# Other metrics -----------------------------------------------------------

## Coefficient of Dispersion

sales_ptax_cod <- sales_ptax %>%
  filter(year >= 2011, outlier_flag_iaao == 1, sale_price_outlier == 1) %>%
  group_by(year) %>%
  mutate(abs_dif = abs(av_ratio_board - median(av_ratio_board))) %>%
  summarise(
    cod = ((sum(abs_dif) / n()) / median(av_ratio_board)),
    n = n()
  )

(cod_chart <- ggplot(data = sales_ptax_cod) +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0, ymax = 0.7), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0, ymax = 0.7), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0, ymax = 0.7), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.2, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2016.5, y = 0.2, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2020.5, y = 0.2, label = "Assessed under\nKaegi")) +
  geom_ribbon(
    aes(
      ymin = 0.05, ymax = 0.15, x = (year - 2016) * (11.9 / 10) + 2016.5
    ),
    fill = "#49DEA4", alpha = 0.5
  ) +
  geom_text(aes(x = 2016.5, y = 0.1, label = "Acceptable CoD")) +
  geom_line(
    aes(x = year, y = cod, color = "Coefficient of Dispersion"),
    lwd = 2
  ) +
  scale_color_manual(values = "#ffc425") +
  scale_y_continuous(name = "Coefficient of Dispersion", limits = c(0, 0.7), expand = c(0, 0), labels = scales::percent_format()) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Coefficient of Dispersion by Tax Year for residential properties",
    captions = caption_3
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

sales_ptax_prd <- sales_ptax %>%
  filter(year >= 2011, outlier_flag_iaao == 1, sale_price_outlier == 1) %>%
  group_by(year) %>%
  summarise(
    mean_av = mean(av_ratio_board, na.rm = TRUE),
    median_av = median(av_ratio_board),
    weighted_mean_av = weighted.mean(av_ratio_board, sale_price_hpi),
    prd = mean_av / weighted_mean_av,
    n = n()
  )

(prd_chart <- ggplot(data = sales_ptax_prd) +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = 0.6, ymax = 2), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = 0.6, ymax = 2), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = 0.6, ymax = 2), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = 0.85, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2016.5, y = 0.85, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2020.5, y = 0.85, label = "Assessed under\nKaegi")) +
  geom_ribbon(
    aes(
      ymin = 0.98, ymax = 1.03, x = (year - 2016) * (11.9 / 10) + 2016.5
    ),
    fill = "#49DEA4", alpha = 0.5
  ) +
  geom_text(aes(x = 2016.5, y = 1.01, label = "Acceptable PRD")) +
  geom_line(
    aes(x = year, y = prd, color = "Price-Related Differential"),
    lwd = 2
  ) +
  scale_color_manual(values = "#ffc425") +
  scale_y_continuous(name = "Price-Related Differential", limits = c(0.6, 2), expand = c(0, 0)) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Price-Related Differential by Tax Year for residential properties",
    captions = caption_3
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

sales_ptax_prb <- sales_ptax %>%
  filter(year >= 2011, outlier_flag_iaao == 1, sale_price_outlier == 1) %>%
  group_by(year) %>%
  mutate(
    value = ((av_board / median(av_ratio_board)) + (sale_price)) / 2,
    ln_value = log(value) / log(2),
    pct_diff = (av_ratio_board - median(av_ratio_board)) / median(av_ratio_board)
  ) %>%
  ungroup() %>%
  select(year, pct_diff, ln_value) %>%
  lmList(pct_diff ~ ln_value | year, data = .) %>%
  coef() %>%
  rownames_to_column("year") %>%
  mutate(year = as.numeric(year))

(prb_chart <- ggplot(data = sales_ptax_prb) +
  geom_rect(mapping = aes(xmin = 2018.55, xmax = 2022.45, ymin = -0.6, ymax = 0.16), fill = "#ceccc4", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2014.55, xmax = 2018.45, ymin = -0.6, ymax = 0.16), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_rect(mapping = aes(xmin = 2010.55, xmax = 2014.45, ymin = -0.6, ymax = 0.16), fill = "#f6f6ed", color = "white", alpha = 0.5) +
  geom_text(aes(x = 2012.5, y = -0.5, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2016.5, y = -0.5, label = "Assessed under\nBerrios")) +
  geom_text(aes(x = 2020.5, y = -0.5, label = "Assessed under\nKaegi")) +
  geom_ribbon(
    aes(
      ymin = -0.05, ymax = 0.05, x = (year - 2016) * (11.9 / 10) + 2016.5
    ),
    fill = "#49DEA4", alpha = 0.5
  ) +
  geom_text(aes(x = 2016.5, y = 0.01, label = "Acceptable PRB")) +
  geom_line(
    aes(x = year, y = ln_value, color = "Coefficient of Price-Related Bias"),
    lwd = 2
  ) +
  scale_color_manual(values = "#ffc425") +
  scale_y_continuous(name = "Coefficient of Price-Related Bias", limits = c(-0.6, 0.16), expand = c(0, 0)) +
  scale_x_continuous(name = "Tax Year", breaks = c(2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021), expand = c(0.01, 0.01)) +
  labs(
    subtitle = "Coefficient of Price-Related Bias by Tax Year for residential properties",
    captions = caption_3
  ) +
  theme_classic() +
  theme(
    legend.position = "bottom",
    plot.subtitle = element_text(size = 13, hjust = .5, face = "bold", color = "#333333"),
    plot.caption = element_text(size = 12, color = "#333333", hjust = 0),
    axis.text = element_text(size = 11, color = "#333333"), axis.title = element_text(size = 14, color = "#333333"),
    legend.text = element_text(size = 13, color = "#333333"),
    legend.title = element_blank(),
    strip.text = element_text(size = 13), strip.background = element_blank(),
    plot.margin = margin(t = 15, r = 20, b = 10, l = 15)
  ))

# -------------------------------------------------------------------------

path_dir <- "viz"

ggsave(plot = cod_chart, filename = paste0(path_dir, "/10-cod_res.pdf"), width = 15, height = 8)
ggsave(plot = prd_chart, filename = paste0(path_dir, "/11-prd_res.pdf"), width = 15, height = 8)
ggsave(plot = prb_chart, filename = paste0(path_dir, "/12-prb_res.pdf"), width = 15, height = 8)

# -------------------------------------------------------------------------
## TEST

# stats_ptax <- sales_ptax %>%
#   filter(year >= 2011, reporting_group != "Condominium") %>%
#   mutate(
#     SALE_PRICE = sale_price,
#     SALE_PRICE_ADJ = sale_price_hpi,
#     ASSESSED_VALUE = av_board,
#     ASSESSED_VALUE_ADJ = av_board_hpi,
#     TAX_YEAR = year,
#     SALE_YEAR = year,
#     RATIO = av_ratio_board
#   ) %>%
#   # cmfproperty::calc_iaao_stats() %>%
#   calc_iaao_stats() %>%
#   mutate(year = Year) %>%
#   mutate(cod = COD / 100) %>%
#   mutate(prd = PRD) %>%
#   mutate(ln_value = PRB)

# ratios <- sales_ptax %>%
#   filter(year >= 2011, reporting_group != "Condominium") %>%
#   cmfproperty::reformat_data(
#     .,
#     sale_col = "sale_price",
#     assessment_col = "av_board",
#     sale_year_col = "year",
#     filter_data = FALSE
#   ) %>%
#   mutate(ADJ_INDEX = SALE_PRICE_ADJ / SALE_PRICE)

# stats_3 <- cmfproperty::calc_iaao_stats(ratios)

# sum(ratios$SALE_YEAR != ratios$TAX_YEAR)
# sum(ratios$ASSESSED_VALUE_ADJ/ratios$SALE_PRICE_ADJ == ratios$RATIO)
# sum(ratios$RATIO != ratios$av_ratio_board)
# sum(ratios$SALE_PRICE_ADJ != ratios$sale_price_hpi)

# ratios %>%
#   group_by(TAX_YEAR) %>%
#   summarise(
#     ADJ_INDEX = mean(ADJ_INDEX),
#     hpi = mean(hpi),
#   )

# ratios %>%
#   mutate(new_r = av_board_hpi/sale_price_hpi) %>%
#   summarise(m = mean(new_r == av_ratio_board))


# table(ratios$arms_length_transaction, ratios$av_ratio_5_to_95)

# cmfproperty::make_report(ratios,
#   jurisdiction_name = "Cook County, Illinois_adj_to_nm",
#   output_dir = "~/Documents"
# )

# -------------------------------------------------------------------------



library(tidycensus)

bg_data <- get_acs(
  year = 2020, geography = "block group",
  survey = "acs5", variables = c("B19013_001"),
  cache_table = TRUE,
  state = "17", county = "031",
  geometry = TRUE
) %>%
  rename_all(list(tolower)) %>%
  select(geoid, estimate, geometry) %>%
  rename(total_population = estimate) %>%
  st_transform(4326)

# PIN geometries
ptax_data_geo <- dbGetQuery(ptaxsim_db_conn, "SELECT pin10, longitude, latitude FROM pin_geometry_raw")

ptax_data_geo <- ptax_data_geo %>%
  st_as_sf(
    coords = c("longitude", "latitude"),
    crs = 4326, agr = "constant"
  ) %>%
  group_by(pin10) %>%
  mutate(dup = row_number()) %>%
  ungroup() %>%
  filter(dup == 1) %>%
  st_join(., bg_data, join = st_within) %>%
  st_drop_geometry() %>%
  select(pin10, geoid) %>%
  filter(!is.na(geoid))

sapply(ptax_data_geo, function(X) sum(is.na(X)))

# -------------------------------------------------------------------------

sales_ptax_bg <- sales_ptax %>%
  filter(
    outlier_flag_iaao == 1,
    year >= 2016
  ) %>%
  mutate(pin10 = str_sub(pin, start = 1L, end = 10L)) %>%
  left_join(., ptax_data_geo, by = c("pin10" = "pin10")) %>%
  filter(outlier_flag_iaao == 1) %>%
  group_by(geoid, year, assessor_term, comparison_years, assessor_term_year, triad_name) %>%
  summarize_at(vars(tax_bill_total_hpi, sale_price_hpi, av_mailed_hpi, av_certified_hpi, av_board_hpi, av_clerk_hpi), list(sum)) %>%
  ungroup() %>%
  filter((triad_name == "City" & comparison_years == "2018 vs. 2021") |
    (triad_name == "North" & comparison_years == "2016 vs. 2019") |
    (triad_name == "South" & comparison_years == "2017 vs. 2020")) %>%
  mutate(
    av_ratio_mailed = av_mailed_hpi / sale_price_hpi,
    av_ratio_board = av_board_hpi / sale_price_hpi,
    av_board_mailed_diff = av_board_hpi - av_mailed_hpi
  )

sales_ptax_bg <- bg_data %>%
  left_join(., sales_ptax_bg, by = c("geoid" = "geoid"))

library(viridis)

(city_map <- ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Berrios", triad_name == "City"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Berrios 2018") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Kaegi", triad_name == "City"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Kaegi 2021") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  plot_annotation(title = "Assessed value ratios (mailed)") +
  plot_layout(ncol = 2, guides = "collect") &
  theme(
    legend.title = element_blank(),
    plot.title = element_text(hjust = .5, face = "bold"),
    plot.subtitle = element_text(hjust = .5)
  ))


(north_map <- ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Berrios", triad_name == "North"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Berrios 2016") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Kaegi", triad_name == "North"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Kaegi 2019") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  plot_annotation(title = "Assessed value ratios (mailed)") +
  plot_layout(ncol = 2, guides = "collect") &
  theme(
    legend.title = element_blank(),
    plot.title = element_text(hjust = .5, face = "bold"),
    plot.subtitle = element_text(hjust = .5)
  ))


(south_map <- ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Berrios", triad_name == "South"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Berrios 2017") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  ggplot() +
  geom_sf(
    data = sales_ptax_bg %>% filter(assessor_term == "Kaegi", triad_name == "South"),
    aes(fill = av_ratio_mailed), color = "#333333", linewidth = .1
  ) +
  labs(subtitle = "Kaegi 2020") +
  scale_fill_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  scale_color_gradient2(low = "#0194D3", mid = "#ffffff", high = "#F77552", midpoint = .1, oob = scales::squish, limits = c(0, .2)) +
  theme_void() +
  plot_annotation(title = "Assessed value ratios (mailed)") +
  plot_layout(ncol = 2, guides = "collect") &
  theme(
    legend.title = element_blank(),
    plot.title = element_text(hjust = .5, face = "bold"),
    plot.subtitle = element_text(hjust = .5)
  ))


ggsave(plot = city_map, filename = paste0(path_dir, "/13-city_map.pdf"), width = 8, height = 7)
ggsave(plot = north_map, filename = paste0(path_dir, "/14-north_av_ratio.pdf"), width = 11, height = 5)
ggsave(plot = south_map, filename = paste0(path_dir, "/15-south_av_ratio.pdf"), width = 10, height = 8)


# # Race / ethnicity regions ------------------------------------------------
#
# tract_data <- get_acs(year = 2020, geography = "tract",
#         survey = 'acs5', variables = c('B19013_001'),
#         cache_table = TRUE,
#         state = '17', county = '031',
#         geometry = TRUE) %>%
#   rename_all(list(tolower))  %>%
#   select(geoid, estimate, geometry) %>%
#   rename(total_population = estimate) %>%
#   st_transform(4326)
#
# tract_data_race  <- get_acs(year = 2020, geography = "tract",
#         survey = 'acs5', variables = c('B03002_012', 'B03002_003', 'B03002_004', 'B03002_005', 'B03002_006', 'B03002_007', 'B03002_008', 'B03002_009'),
#         summary_var = 'B03002_001',
#         cache_table = TRUE,
#         state = '17', county = '031',
#         geometry = FALSE)
#
# tract_data_race <- tract_data_race %>%
#   rename_all(list(tolower)) %>%
#   mutate(variable_label = case_when(variable == 'B03002_012' ~ 'Latino/a',
#                                     variable == 'B03002_003' ~ 'White',
#                                     variable == 'B03002_004' ~ 'Black',
#                                     variable == 'B03002_005' ~ 'Other',
#                                     variable == 'B03002_006' ~ 'Asian',
#                                     variable == 'B03002_007' ~ 'Asian',
#                                     variable == 'B03002_008' ~ 'Other',
#                                     variable == 'B03002_009' ~ 'Other',
#                                     TRUE ~ as.character(''))) %>%
#   group_by(geoid, variable_label, summary_est) %>%
#   summarize_at(.vars = vars(estimate), .funs = list(sum)) %>%
#   ungroup()
#
# tract_data_plurality_race <- tract_data_race  %>%
#   mutate(plurality_race_share = estimate/summary_est) %>%
#   group_by(geoid) %>%
#   mutate(plurality_rank = row_number(desc(plurality_race_share))) %>%
#   ungroup() %>%
#   #filter(estimate > 0) %>%
#   select(geoid, variable_label, estimate, plurality_race_share, plurality_rank) %>%
#   rename(plurality_race_population = estimate,
#          plurality_race = variable_label) %>%
#   filter(plurality_rank == 1) %>%
#   select(geoid, plurality_race, plurality_race_population, plurality_race_share)
#
# # Dissolve tract geometries by plurality race
# tract_data_grouped <- tract_data %>%
#   left_join(., tract_data_plurality_race, by = c('geoid' = 'geoid')) %>%
#   filter(!is.na(plurality_race))  %>%
#   st_make_valid() %>%
#   group_by(plurality_race) %>%
#   dplyr::summarize(geometry = st_union(geometry)) %>%
#   ungroup() %>%
#   st_cast("MULTIPOLYGON") %>% st_cast("POLYGON") %>%
#   st_transform(3395) %>%
#   mutate(area = st_area(.)) %>%
#   st_transform(4326) %>%
#   group_by(plurality_race) %>%
#   mutate(area_rank = row_number(desc(area))) %>%
#   ungroup() %>%
#   mutate(area_share = as.numeric(area/sum(area)))%>%
#   filter(area_rank <= 2 | area_share >= .01) %>% # must have area over 1% or 1 cluster per race
#   select(plurality_race, geometry)
#
# ggplot() +
#   geom_sf(data = tract_data_grouped, aes(fill = plurality_race))
#
# st_rook = function(a, b = a) st_relate(a, b, pattern = "F***1****")
#
# # Join dissolved clusters to tract data so every tract is assigned to its closest cluster
# tract_data_clusters <- tract_data %>%
#   st_make_valid() %>%
#   select(geoid, total_population, geometry) %>%
#   st_join(x = ., y = tract_data_grouped %>% st_make_valid(), left = TRUE, largest = TRUE) %>%
#   filter(!st_is_empty(.)) %>%
#   st_join(x = ., y = tract_data_grouped %>% st_make_valid(), join = nngeo::st_nn) %>%
#   mutate(plurality_race = coalesce(plurality_race.x, plurality_race.y))
#
# # Re-dissolve tract map into complete cluster map
# tract_data_clusters_grouped <- tract_data_clusters %>%
#   select(plurality_race, geometry) %>%
#   group_by(plurality_race) %>%
#   dplyr::summarize(geometry = st_union(geometry)) %>%
#   ungroup() %>%
#   st_make_valid() %>%
#   st_cast(., "POLYGON") %>%
#   arrange(plurality_race) %>%
#   mutate(cluster_group = row_number())
#
# ggplot() +
#   geom_sf(data = tract_data_clusters_grouped, aes(fill = plurality_race), color = 'white') +
#   theme_void()
