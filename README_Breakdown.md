# Breakdown

## SALES DATA

### Source

<https://datacatalog.cookcountyil.gov/Property-Taxation/Assessor-Parcel-Sales/wvhk-k5uv>

### Data processing steps

1. Read data
    - n = 2172215
2. Filter to `year`>=2011
    - n = 1089881
3. Filter to include only one most recent sale for every `pin`-`year`
    - n = 1058891

## PTAX DATA

### DB details

#### Version

(ptaxsim-2021.0.4.db)

#### Query

`SELECT year, pin, tax_code_num, class, tax_bill_total, av_mailed, av_certified, av_board, av_clerk FROM pin where year >= 2011`  
n = 20495988

### Data processing steps

## APPEALS DATA

### Source

<https://datacatalog.cookcountyil.gov/Property-Taxation/Board-of-Review-Appeal-Decision-History/7pny-nedm>

### Data processing steps

1. Read data
    - n = 5316337
2. Filter to `tax_year`>=2011
    - n = 4940613
3. Filter to remove `Class` being 0[^1]
    - n = 4938255
4. Create `class_char`, a character representation of the class
    - If `Class` is 3 digits (i.e. <1000), keep
    - Else take `Class/100` and keep (for 5 digit representations)
5. Inner join w `class_data` on `class_char/class_code`
    - n = 4938249
    - Removes 6 entries w `Class = 919`, not in current code list
[^1]: Also removes some properties with non-zero post review valuations

## SALES PTAX

### Data processing steps

0. Start w [PTAX DATA](#ptax-data)
1. Filter to `year` between 2011 and 2022 inclusive
2. Inner join w [`class_data`](#class-data) restricted to `regression_class=TRUE` on `class/class_code`
    - n = 17027479
3. Create `township_code` w first 2 characters of `tax_code_num`
4. Left join `ccao::town_shp` on `township_code`
5. Create left padded 14-digit PIN using `pin`
6. Inner join w [SALES DATA](#sales-data) on `year` and `pin`
    - n = 853174
7. Create ratios as follows
    - `av_ratio_mailed = av_mailed / sale_price`
    - `av_ratio_certified = av_certified / sale_price`
    - `av_ratio_board = av_board / sale_price`
    - `av_ratio_clerk = av_clerk / sale_price`
8. Group by `year, township_code, class`
9. Flag outliers (`outlier_flag_iaao`) using `av_ratio_mailed` being more than 1.5x IQR away from 25th/75th percentile (NOT FILTERED, ONLY FLAGGED)
10. Left join w housing CPI, Case-Shiller, and FHFA HPI (all 2023) on `year`
11. Create indexed values of `tax_bill_total, sale_price, av_mailed, av_certified, av_board, av_clerk` using CPI, Case-Shiller, and FHFA HPI
12. Filter out `reporting_group` equal to `Bed & Breakfast`
    - n = 853168
13. Create `assessor_term` as follows
    - 1998 - 2010 - Houlihan
    - 2011 - 2018 - Berrios
    - 2019 - 2024 - Kaegi
14. Create `comparison_years`
    - 2018/2021
    - 2017/2020
    - 2016/2019

## SUMMARIES

### SALES PTAX SUMMARY

0. Start w [SALES PTAX](#sales-ptax)
1. Filter to `year` > 2016 and `outlier_flag_iaao` = 1
    n = 469914
2. Filter to sales within year of reassessment of region
    - 2018/2021 - City
    - 2017/2020 - South
    - 2016/2019 - North
        - n = 162237
3. Group by `year, reporting group`
4. Create percentiles `n_tile`
5. Group by `reporting_group, sales_ntile, comparison_years, assessor_term, assessor_term_year` - equivalent to `reporting_group, sales_ntile, assessor_term_year`
6. Summarise
    - `count`
    - `av_ratio_mailed` = mean of `av_ratio_mailed`
    - `sale_price` = mean of `sale_price`
    - `sale_price_cpi` = mean of `sale_price_cpi`
    - `sale_price_hpi` = mean of `sale_price_hpi`
__Plots on Slides 2 to 3 follow from this__
Values w AV ratio > 0.3 (n=5) and sale price hpi > 1M (n = 128) are removed

### SALES PTAX SUMMARY BY TRIAD

0. Start w [SALES PTAX](#sales-ptax)
1. Filter to `year` > 2016 and `outlier_flag_iaao` = 1
    n = 469914
2. Group by `year, reporting group, triad_name`
3. Create percentiles `n_tile`
4. Group by `reporting_group, sales_ntile, comparison_years, assessor_term, assessor_term_year` - equivalent to `reporting_group, sales_ntile, assessor_term_year`
5. Summarise
    - `count`
    - `av_ratio_mailed` = mean of `av_ratio_mailed`
    - `sale_price` = mean of `sale_price`
    - `sale_price_cpi` = mean of `sale_price_cpi`
    - `sale_price_hpi` = mean of `sale_price_hpi`
__Plots on Slides 4 to 9 follow from this__
For City of Chicago, values w AV ratio > 0.3 (n=1) and sale price hpi > 1M (n = 59) are removed
For North Suburbs, values w AV ratio > 0.3 (n=0) and sale price hpi > 1M (n = 53) are removed
For South Suburbs, values w AV ratio > 0.3 (n=4) and sale price hpi > 1M (n = 16) are removed

### SALES PTAX SUMMARY PRE/POST BOARD OF REVIEW

0. Start w [SALES PTAX](#sales-ptax)
1. Filter to `year` > 2019 and `outlier_flag_iaao` = 1
    - n = 233668
2. Group by `year`
3. Create percentiles `n_tile`
4. Group by `year, sales_ntile, assessor_term` - equivalent to `year, sales_ntile`
5. Summarise
    - `count`
    - `av_mailed_cpi` = mean of `av_mailed_cpi`
    - `av_board_cpi` = mean of `av_board_cpi`
    - `av_mailed_hpi` = mean of `av_mailed_hpi`
    - `av_board_hpi` = mean of `av_board_hpi`
    - `av_ratio_mailed` = mean of `av_ratio_mailed`
    - `av_ratio_board` = mean of `av_ratio_board`
    - `sale_price` = mean of `sale_price`
    - `sale_price_cpi` = mean of `sale_price_cpi`
    - `sale_price_hpi` = mean of `sale_price_hpi`
6. After ungroup, create -
    - `assessed_value_board_mailed_ratio` = `av_board_cpi / av_mailed_cpi`,
    - `assessed_value_board_mailed_diff` = `av_board_cpi - av_mailed_cpi`,
    - `assessed_value_board_mailed_diff_pct` = `assessed_value_board_mailed_diff / av_mailed_cpi`
7. Pivot longer with all previously created variables in Steps 5 and 6 (EXCEPT the sales prices)
__Plots on Slide 15 follows from this__
For Absolute Difference, values w `assessed_value_board_mailed_diff` < 15k (n=1), `assessed_value_board_mailed_diff` > 10 (n=0), and sale price hpi > 1M (n = 20) are removed
For Percentage Difference, values w `assessed_value_board_mailed_diff_pct` > 0% (n=0), `assessed_value_board_mailed_diff_pct` < -20% (n=1), and sale price hpi > 1M (n = 20) are removed

### PTAX DATA COMPOSITION ABSOLUTE

0. Start w [PTAX DATA](#ptax-data)
1. Filter to `year` between 2011 and 2022 inclusive (already only contains 2011-2021)
    - n = 20495988
2. Inner join w [`class_data`](#class-data) on `class/class_code`
3. Create `township_code` w first 2 characters of `tax_code_num`
4. Left join `ccao::town_shp` on `township_code`
5. Create left padded 14-digit PIN using `pin`
6. Group by `year, major class type`
7. Summarise -
    - `tax_bill_total` = sum of `tax_bill_total`
    - `av_mailed` = sum of `av_mailed`
    - `av_board` = sum of `av_board`
    - `av_certified` = sum of `av_certified`
    - `av_clerk` = sum of `av_clerk`
8. Pivot longer with all previously created variables in Step 7
9. Filter to only keep rows related to `tax_bill_total, av_board, av_mailed`

### PTAX DATA COMPOSITION RELATIVE

0. Start w [PTAX DATA](#ptax-data)
1. Filter to `year` between 2011 and 2022 inclusive (already only contains 2011-2021)
    - n = 20495988
2. Inner join w [`class_data`](#class-data) on `class/class_code`
3. Create `township_code` w first 2 characters of `tax_code_num`
4. Left join `ccao::town_shp` on `township_code`
5. Create left padded 14-digit PIN using `pin`
6. Group by `year, major class type`
7. Summarise -
    - `tax_bill_total` = sum of `tax_bill_total`
    - `av_mailed` = sum of `av_mailed`
    - `av_board` = sum of `av_board`
    - `av_certified` = sum of `av_certified`
    - `av_clerk` = sum of `av_clerk`
8. Group by `year`
9. Create -
    - `tax_bill_total_sum` = sum of `tax_bill_total` for the `year`
    - `av_mailed_sum` = sum of `av_mailed` for the `year`
    - `av_board_sum` = sum of `av_board` for the `year`
    - `av_certified_sum` = sum of `av_certified` for the `year`
    - `av_clerk_sum` = sum of `av_clerk` for the `year`
10. Ungroup, then create
    - `tax_bill_total_share` = `tax_bill_total` / `tax_bill_total_sum`
    - `av_mailed_share` = `av_mailed` / `av_mailed_sum`
    - `av_board_share` = `av_board` / `av_board_sum`
    - `av_certified_share` = `av_certified` / `av_certified_sum`
    - `av_clerk_share` = `av_clerk` / `av_clerk_sum`
11. Pivot longer with all previously created variables in Step 10
12. Filter to only keep rows related to `tax_bill_total_share, av_board_share, av_mailed_share`

### PTAX CLASS-YEAR SUMMARY

0. Start w [PTAX DATA](#ptax-data)
1. Filter to `year` between 2011 and 2022 inclusive
2. Inner join w [`class_data`](#class-data) on `class/class_code`
3. Group by `year, major_class_type`
4. Summarise
    - `pin_total_count` = `n`
    - `av_board_sum` = sum of `av_board`
summarised n = 19438323[^2]

[^2]: Loss of n due to exempt class (n = 1057665) and classes not in current code list (20)

### PTAX CLASS-YEAR-TRIAD SUMMARY

0. Start w [PTAX DATA](#ptax-data)
1. Filter to `year` between 2011 and 2022 inclusive
2. Inner join w [`class_data`](#class-data) on `class/class_code`
3. Create `township_code` w first 2 characters of `tax_code_num`
4. Left join `ccao::town_shp` on `township_code`
5. Group by `year, major_class_type, triad_name`
6. Summarise
    - `pin_total_count` = `n`
    - `av_board_sum` = sum of `av_board`
summarised n = 19438323[^2]

### APPEALS SUMMARY

0. Start w [APPEALS DATA](#appeals-data)
1. Group by tax_year, [`major_class_type`](#class-data), Result of appeal
2. Summarise
    - `count` = `n`
    - `assessor_total` = sum of `Assessor_TotalValue`
    - `bor_total` = sum of `BOR_TotalValue`
3. Inner join w [PTAX CLASS-YEAR SUMMARY](#ptax-class-year-summary) on `tax_year/year` and `major_class_type`
4. Create `ratio = count / pin_total_count`

### APPEALS SUMMARY BY TRIAD

1. Left join `ccao::town_shp` on `township_code`
2. Group by tax_year, [res_nonres_label](#class-data), Result of appeal, Triad
3. Summarise
    - `count` = `n`
    - `assessor_total` = sum of `Assessor_TotalValue`
    - `bor_total` = sum of `BOR_TotalValue`
4. Inner join w [PTAX CLASS-YEAR-TRIAD SUMMARY](#ptax-class-year-triad-summary) on `tax_year/year`, `triad_name` and `major_class_type`
5. Create `ratio = count / pin_total_count`

## CLASS DATA

|class_code |res_nonres_label |reporting_group |regression_class |class_desc                                                                                                                                                    |
|:----------|:----------------|:---------------|:----------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------|
|NA         |Non-residential  |NA              |FALSE            |Exempt property                                                                                                                                               |
|NA         |Non-residential  |NA              |FALSE            |Railroad property                                                                                                                                             |
|100        |Non-residential  |NA              |FALSE            |Vacant land                                                                                                                                                   |
|190        |Non-residential  |NA              |FALSE            |Minor improvement on vacant land                                                                                                                              |
|200        |Residential      |NA              |FALSE            |Residential land                                                                                                                                              |
|201        |Residential      |NA              |FALSE            |Residential garage                                                                                                                                            |
|202        |Residential      |Single-Family   |TRUE             |One story residence, any age, up to 999 sq. ft.                                                                                                               |
|203        |Residential      |Single-Family   |TRUE             |One story residence, any age, 1,000 to 1,800 sq. ft.                                                                                                          |
|204        |Residential      |Single-Family   |TRUE             |One story residence, any age, 1,801 sq. ft. and over                                                                                                          |
|205        |Residential      |Single-Family   |TRUE             |Two or more story residence, over 62 years, up to 2,200 sq. ft                                                                                                |
|206        |Residential      |Single-Family   |TRUE             |Two or more story residence, over 62 years, 2,201 to 4,999 sq. ft.                                                                                            |
|207        |Residential      |Single-Family   |TRUE             |Two or more story residence, up to 62 years, up to 2,000 sq. ft.                                                                                              |
|208        |Residential      |Single-Family   |TRUE             |Two or more story residence, up to 62 years, 3,801 to 4,999 sq. ft.                                                                                           |
|209        |Residential      |Single-Family   |TRUE             |Two or more story residence, any age, 5,000 sq. ft. and over                                                                                                  |
|210        |Residential      |Single-Family   |TRUE             |Old style townhouse, over 62 years                                                                                                                            |
|211        |Residential      |Multi-Family    |TRUE             |Two to six residential apartments, any age                                                                                                                    |
|212        |Residential      |Multi-Family    |TRUE             |Two to six mixed-use apartments, any age, up to 20,000 sq. ft.                                                                                                |
|213        |Residential      |NA              |FALSE            |Cooperative                                                                                                                                                   |
|218        |Residential      |Bed & Breakfast |TRUE             |A residential building licensed as a Bed & Breakfast by the municipality                                                                                      |
|219        |Residential      |Bed & Breakfast |TRUE             |A residential building licensed as a Bed & Breakfast by the municipality                                                                                      |
|224        |Residential      |NA              |FALSE            |Farm building                                                                                                                                                 |
|225        |Residential      |NA              |FALSE            |Single-room occupancy rental building                                                                                                                         |
|234        |Residential      |Single-Family   |TRUE             |Spllit level residence, with a lower level below grade, all ages, all sizes                                                                                   |
|236        |Residential      |NA              |FALSE            |Any residence located on a parcel used primarily for commercial or industrial purposes                                                                        |
|239        |Residential      |NA              |FALSE            |Non-equalized land under agricultural use, valued at farm pricing                                                                                             |
|240        |Residential      |NA              |FALSE            |First-time agricultural use of land valued at market price                                                                                                    |
|241        |Residential      |NA              |FALSE            |Vacant land under common ownership with adjacent residence                                                                                                    |
|278        |Residential      |Single-Family   |TRUE             |Two or more story residence, up to 62 years, 2,001 to 3,800 sq. ft.                                                                                           |
|288        |Residential      |NA              |FALSE            |Home improvement                                                                                                                                              |
|290        |Residential      |NA              |FALSE            |Minor improvement                                                                                                                                             |
|295        |Residential      |Single-Family   |TRUE             |Individually owned row houses or townhouses, up to 62 years                                                                                                   |
|297        |Residential      |NA              |FALSE            |Special residential improvements (May apply to condo building in first year of construction before division into individual units.)                           |
|299        |Residential      |Condominium     |TRUE             |Condominium                                                                                                                                                   |
|300        |Non-residential  |NA              |FALSE            |Land used in conjunction with rental apartments                                                                                                               |
|301        |Non-residential  |NA              |FALSE            |Garage used in conjunction with rental apartments                                                                                                             |
|313        |Non-residential  |NA              |FALSE            |Two-or-three-story, building, seven or more units                                                                                                             |
|314        |Non-residential  |NA              |FALSE            |Two-or-three-story, non-fireproof building with corridor apartment or California type apartments, no corridors exterior entrance                              |
|315        |Non-residential  |NA              |FALSE            |Two-or-three-story, non-fireproof corridor apartments or California type apartments, interior entrance                                                        |
|318        |Non-residential  |NA              |FALSE            |Mixed-use commercial/residential building with apartments and commercial area totaling seven units or more with a square-foot area of over 20,000 square feet |
|390        |Non-residential  |NA              |FALSE            |Other minor improvement related to rental use                                                                                                                 |
|391        |Non-residential  |NA              |FALSE            |Apartment building over three stories, seven or more units                                                                                                    |
|396        |Non-residential  |NA              |FALSE            |Rented modern row houses, seven or more units in a single development or one or more contiguous parcels in common ownership                                   |
|397        |Non-residential  |NA              |FALSE            |Special rental structure                                                                                                                                      |
|399        |Non-residential  |Condominium     |TRUE             |Rental condominium                                                                                                                                            |
|400        |Non-residential  |NA              |FALSE            |Not-for-profit land                                                                                                                                           |
|401        |Non-residential  |NA              |FALSE            |Not-for-profit garage                                                                                                                                         |
|417        |Non-residential  |NA              |FALSE            |Not-for-profit one story commercial building                                                                                                                  |
|418        |Non-residential  |NA              |FALSE            |Not-for-profit two-or-three story mixed use commercial/residential building                                                                                   |
|422        |Non-residential  |NA              |FALSE            |Not-for-profit one-story non-fireproof public garage                                                                                                          |
|423        |Non-residential  |NA              |FALSE            |Not-for-profit gasoline station                                                                                                                               |
|426        |Non-residential  |NA              |FALSE            |Not-for-profit commercial greenhouse                                                                                                                          |
|427        |Non-residential  |NA              |FALSE            |Not-for-profit theatre                                                                                                                                        |
|428        |Non-residential  |NA              |FALSE            |Not-for-profit bank building                                                                                                                                  |
|429        |Non-residential  |NA              |FALSE            |Not-for-profit motel                                                                                                                                          |
|430        |Non-residential  |NA              |FALSE            |Not-for-profit supermarket                                                                                                                                    |
|431        |Non-residential  |NA              |FALSE            |Not-for-profit shopping center                                                                                                                                |
|432        |Non-residential  |NA              |FALSE            |Not-for-profit bowling alley                                                                                                                                  |
|433        |Non-residential  |NA              |FALSE            |Not-for-profit quonset hut or butler type building                                                                                                            |
|435        |Non-residential  |NA              |FALSE            |Not-for-profit golf course improvement                                                                                                                        |
|480        |Non-residential  |NA              |FALSE            |Not-for-profit industrial minor improvement                                                                                                                   |
|481        |Non-residential  |NA              |FALSE            |Not-for-profit garage used in conjunction with industrial improvement                                                                                         |
|483        |Non-residential  |NA              |FALSE            |Not-for-profit industrial quonset hut or butler type building                                                                                                 |
|487        |Non-residential  |NA              |FALSE            |Not-for-profit special industrial improvement                                                                                                                 |
|489        |Non-residential  |NA              |FALSE            |Not-for-profit industrial condominium                                                                                                                         |
|490        |Non-residential  |NA              |FALSE            |Not-for-profit commercial minor improvement                                                                                                                   |
|491        |Non-residential  |NA              |FALSE            |Not-for-profit improvement over three stories                                                                                                                 |
|492        |Non-residential  |NA              |FALSE            |Not-for-profit two-or-three story building containing part or all retail and/or commercial space                                                              |
|493        |Non-residential  |NA              |FALSE            |Not-for-profit industrial building                                                                                                                            |
|496        |Non-residential  |NA              |FALSE            |Not-for-profit rented modern row houses, seven or more units in a single development                                                                          |
|497        |Non-residential  |NA              |FALSE            |Not-for-profit special structure                                                                                                                              |
|499        |Non-residential  |NA              |FALSE            |Not-for-profit condominium                                                                                                                                    |
|500        |Non-residential  |NA              |FALSE            |Commercial land                                                                                                                                               |
|501        |Non-residential  |NA              |FALSE            |Golf course land                                                                                                                                              |
|516        |Non-residential  |NA              |FALSE            |Non-fireproof hotel or rooming house (apartment hotel)                                                                                                        |
|517        |Non-residential  |NA              |FALSE            |One-story commercial building                                                                                                                                 |
|522        |Non-residential  |NA              |FALSE            |One-story, non-fireproof public garage                                                                                                                        |
|523        |Non-residential  |NA              |FALSE            |Gasoline station                                                                                                                                              |
|526        |Non-residential  |NA              |FALSE            |Commercial greenhouse                                                                                                                                         |
|527        |Non-residential  |NA              |FALSE            |Theatre                                                                                                                                                       |
|528        |Non-residential  |NA              |FALSE            |Bank building                                                                                                                                                 |
|529        |Non-residential  |NA              |FALSE            |Motel                                                                                                                                                         |
|530        |Non-residential  |NA              |FALSE            |Supermarket                                                                                                                                                   |
|531        |Non-residential  |NA              |FALSE            |Shopping center                                                                                                                                               |
|532        |Non-residential  |NA              |FALSE            |Bowling alley                                                                                                                                                 |
|533        |Non-residential  |NA              |FALSE            |Quonset hut or butler type building                                                                                                                           |
|535        |Non-residential  |NA              |FALSE            |Golf course improvement                                                                                                                                       |
|590        |Non-residential  |NA              |FALSE            |Commercial minor improvement                                                                                                                                  |
|591        |Non-residential  |NA              |FALSE            |Commercial building over three stories                                                                                                                        |
|592        |Non-residential  |NA              |FALSE            |Two-or-three-story building containing part or all retail and/or commercial space                                                                             |
|597        |Non-residential  |NA              |FALSE            |Special commercial structure                                                                                                                                  |
|599        |Non-residential  |NA              |FALSE            |Commercial condominium unit                                                                                                                                   |
|550        |Non-residential  |NA              |FALSE            |Industrial land                                                                                                                                               |
|580        |Non-residential  |NA              |FALSE            |Industrial minor improvement                                                                                                                                  |
|581        |Non-residential  |NA              |FALSE            |Garage used in conjunction with industrial improvement                                                                                                        |
|583        |Non-residential  |NA              |FALSE            |Industrial quonset hut or butler type building                                                                                                                |
|587        |Non-residential  |NA              |FALSE            |Special industrial improvement                                                                                                                                |
|589        |Non-residential  |NA              |FALSE            |Industrial condominium unit                                                                                                                                   |
|593        |Non-residential  |NA              |FALSE            |Industrial building                                                                                                                                           |
|650        |Non-residential  |NA              |FALSE            |Industrial land                                                                                                                                               |
|680        |Non-residential  |NA              |FALSE            |Industrial minor improvement                                                                                                                                  |
|681        |Non-residential  |NA              |FALSE            |Garage used in conjunction with industrial incentive improvement                                                                                              |
|683        |Non-residential  |NA              |FALSE            |Industrial quonset hut or butler type building                                                                                                                |
|687        |Non-residential  |NA              |FALSE            |Special industrial improvement                                                                                                                                |
|689        |Non-residential  |NA              |FALSE            |Industrial condominium unit                                                                                                                                   |
|693        |Non-residential  |NA              |FALSE            |Industrial building                                                                                                                                           |
|651        |Non-residential  |NA              |FALSE            |Industrial land                                                                                                                                               |
|663        |Non-residential  |NA              |FALSE            |Industrial building                                                                                                                                           |
|670        |Non-residential  |NA              |FALSE            |Industrial minor improvement                                                                                                                                  |
|671        |Non-residential  |NA              |FALSE            |Garage used in conjunction with industrial incentive improvement                                                                                              |
|673        |Non-residential  |NA              |FALSE            |Industrial quonset hut or butler type building                                                                                                                |
|677        |Non-residential  |NA              |FALSE            |Special industrial improvement                                                                                                                                |
|679        |Non-residential  |NA              |FALSE            |Industrial condominium unit                                                                                                                                   |
|637        |Non-residential  |NA              |FALSE            |Industrial Brownfield land                                                                                                                                    |
|638        |Non-residential  |NA              |FALSE            |Industrial Brownfield                                                                                                                                         |
|654        |Non-residential  |NA              |FALSE            |Other industrial Brownfield minor improvements                                                                                                                |
|655        |Non-residential  |NA              |FALSE            |Garage used in conjunction with industrial Brownfield incentive improvement                                                                                   |
|666        |Non-residential  |NA              |FALSE            |Industrial Brownfield quonset hut or butler type building                                                                                                     |
|668        |Non-residential  |NA              |FALSE            |Special industrial Brownfield improvement                                                                                                                     |
|669        |Non-residential  |NA              |FALSE            |Industrial Brownfield condominium unit                                                                                                                        |
|700        |Non-residential  |NA              |FALSE            |Commercial incentive land                                                                                                                                     |
|701        |Non-residential  |NA              |FALSE            |Garage used in conjunction with Commercial Incentive improvement                                                                                              |
|716        |Non-residential  |NA              |FALSE            |Non-Fireproof hotel or rooming house (Apartment hotel)                                                                                                        |
|717        |Non-residential  |NA              |FALSE            |One-story commercial use building                                                                                                                             |
|722        |Non-residential  |NA              |FALSE            |Garage, service station                                                                                                                                       |
|723        |Non-residential  |NA              |FALSE            |Gasoline station, with /without bays, store                                                                                                                   |
|726        |Non-residential  |NA              |FALSE            |Commercial greenhouse                                                                                                                                         |
|727        |Non-residential  |NA              |FALSE            |Theatre                                                                                                                                                       |
|728        |Non-residential  |NA              |FALSE            |Bank building                                                                                                                                                 |
|729        |Non-residential  |NA              |FALSE            |Motel                                                                                                                                                         |
|730        |Non-residential  |NA              |FALSE            |Supermarket                                                                                                                                                   |
|731        |Non-residential  |NA              |FALSE            |Shopping center                                                                                                                                               |
|732        |Non-residential  |NA              |FALSE            |Bowling alley                                                                                                                                                 |
|733        |Non-residential  |NA              |FALSE            |Quonset hut or butler type building                                                                                                                           |
|735        |Non-residential  |NA              |FALSE            |Golf course improvement                                                                                                                                       |
|790        |Non-residential  |NA              |FALSE            |Other minor commercial improvement                                                                                                                            |
|791        |Non-residential  |NA              |FALSE            |Office building (One story, low, rise, mid rise, high rise)                                                                                                   |
|792        |Non-residential  |NA              |FALSE            |Two-or-three-story building containing part or all retail and/or commercial space                                                                             |
|797        |Non-residential  |NA              |FALSE            |Special commercial structure                                                                                                                                  |
|799        |Non-residential  |NA              |FALSE            |Commercial/Industrial-Condominium unit/garage                                                                                                                 |
|742        |Non-residential  |NA              |FALSE            |Commercial incentive land                                                                                                                                     |
|743        |Non-residential  |NA              |FALSE            |Garage used in conjunction with commercial incentive improvement                                                                                              |
|745        |Non-residential  |NA              |FALSE            |Golf course improvement                                                                                                                                       |
|746        |Non-residential  |NA              |FALSE            |Non-Fireproof hotel or rooming house (Apartment hotel)                                                                                                        |
|747        |Non-residential  |NA              |FALSE            |One-story commercial building                                                                                                                                 |
|748        |Non-residential  |NA              |FALSE            |Motel                                                                                                                                                         |
|752        |Non-residential  |NA              |FALSE            |Garage, service station                                                                                                                                       |
|753        |Non-residential  |NA              |FALSE            |Gasoline station, with/without bays, store                                                                                                                    |
|756        |Non-residential  |NA              |FALSE            |Commercial greenhouse                                                                                                                                         |
|757        |Non-residential  |NA              |FALSE            |Theatre                                                                                                                                                       |
|758        |Non-residential  |NA              |FALSE            |Bank building                                                                                                                                                 |
|760        |Non-residential  |NA              |FALSE            |Supermarket                                                                                                                                                   |
|761        |Non-residential  |NA              |FALSE            |Shopping center (Regional, community, neighborhood, promotional, specialty)                                                                                   |
|762        |Non-residential  |NA              |FALSE            |Bowling alley                                                                                                                                                 |
|764        |Non-residential  |NA              |FALSE            |Quonset hut or butler type building                                                                                                                           |
|765        |Non-residential  |NA              |FALSE            |Other minor commercial improvements                                                                                                                           |
|767        |Non-residential  |NA              |FALSE            |Special commercial structure                                                                                                                                  |
|772        |Non-residential  |NA              |FALSE            |Two-or-three-story building, containing part or all retail and/or commercial space                                                                            |
|774        |Non-residential  |NA              |FALSE            |Office building                                                                                                                                               |
|798        |Non-residential  |NA              |FALSE            |Commercial/Industrial-condominium units/garage                                                                                                                |
|800        |Non-residential  |NA              |FALSE            |Commercial incentive land                                                                                                                                     |
|850        |Non-residential  |NA              |FALSE            |Industrial incentive land                                                                                                                                     |
|801        |Non-residential  |NA              |FALSE            |Garage used in conjunction with commercial incentive improvement                                                                                              |
|816        |Non-residential  |NA              |FALSE            |Non-fireproof hotel or rooming house (apartment hotel)                                                                                                        |
|817        |Non-residential  |NA              |FALSE            |One-story commercial building                                                                                                                                 |
|822        |Non-residential  |NA              |FALSE            |Garage, service station                                                                                                                                       |
|823        |Non-residential  |NA              |FALSE            |Gasoline station with/without bay, store                                                                                                                      |
|826        |Non-residential  |NA              |FALSE            |Commercial greenhouse                                                                                                                                         |
|827        |Non-residential  |NA              |FALSE            |Theatre                                                                                                                                                       |
|828        |Non-residential  |NA              |FALSE            |Bank building                                                                                                                                                 |
|829        |Non-residential  |NA              |FALSE            |Motel                                                                                                                                                         |
|830        |Non-residential  |NA              |FALSE            |Supermarket                                                                                                                                                   |
|831        |Non-residential  |NA              |FALSE            |Shopping center (Regional, community, neighborhood, promotional, specialty)                                                                                   |
|832        |Non-residential  |NA              |FALSE            |Bowling alley                                                                                                                                                 |
|833        |Non-residential  |NA              |FALSE            |Quonset hut or butler type building                                                                                                                           |
|835        |Non-residential  |NA              |FALSE            |Golf course improvement                                                                                                                                       |
|880        |Non-residential  |NA              |FALSE            |Industrial minor improvement                                                                                                                                  |
|881        |Non-residential  |NA              |FALSE            |Garage used in conjunction with industrial incentive improvement                                                                                              |
|883        |Non-residential  |NA              |FALSE            |Quonset hut or butler type building                                                                                                                           |
|887        |Non-residential  |NA              |FALSE            |Special industrial improvement                                                                                                                                |
|889        |Non-residential  |NA              |FALSE            |Industrial condominium unit                                                                                                                                   |
|890        |Non-residential  |NA              |FALSE            |Minor industrial improvement                                                                                                                                  |
|891        |Non-residential  |NA              |FALSE            |Office building                                                                                                                                               |
|892        |Non-residential  |NA              |FALSE            |Two-or-three-story building containing part or all retail and/or commercial space                                                                             |
|893        |Non-residential  |NA              |FALSE            |Industrial building                                                                                                                                           |
|897        |Non-residential  |NA              |FALSE            |Special commercial structure                                                                                                                                  |
|899        |Non-residential  |NA              |FALSE            |Commercial/Industrial condominium unit/garage                                                                                                                 |
|900        |Non-residential  |NA              |FALSE            |Land used in conjunction with incentive rental apartments                                                                                                     |
|901        |Non-residential  |NA              |FALSE            |Garage used in conjunction with incentive rental apartment                                                                                                    |
|913        |Non-residential  |NA              |FALSE            |Two-or-three-story apartment building, seven or more units                                                                                                    |
|914        |Non-residential  |NA              |FALSE            |Two-or-three-story, non-fireproof court and corridor apartments or California type apartments, no corridors, exterior entrance                                |
|915        |Non-residential  |NA              |FALSE            |Two-or-three-story, non-fireproof corridor apartments, or California type apartments, interior entrance                                                       |
|918        |Non-residential  |NA              |FALSE            |Mixed use commercial/residential building with apartments and commercial area where the commercial area is granted an incentive use                           |
|959        |Non-residential  |NA              |FALSE            |Rental condominium unit                                                                                                                                       |
|990        |Non-residential  |NA              |FALSE            |Other minor improvements                                                                                                                                      |
|991        |Non-residential  |NA              |FALSE            |Apartment buildings over three stories                                                                                                                        |
|996        |Non-residential  |NA              |FALSE            |Rented modern row houses, seven or more units in a single development or one or more contiguous parcels in common ownership                                   |
|997        |Non-residential  |NA              |FALSE            |Special rental structure                                                                                                                                      |
