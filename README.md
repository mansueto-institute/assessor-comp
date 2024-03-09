### Comparative analysis of Assessor's in Chicago

Download PDF outputs here: https://uchicago.box.com/s/cnsbcozmao9z5kt0gwhlf041cmvcjei2

Download data sources here: 
* Parcel sales: https://datacatalog.cookcountyil.gov/Property-Taxation/Assessor-Parcel-Sales/wvhk-k5uv
* Property tax bills: https://github.com/ccao-data/ptaxsim#ptaxsim
* BoR appeals:  https://datacatalog.cookcountyil.gov/Property-Taxation/Board-of-Review-Appeal-Decision-History/7pny-nedm/about_data

The data universe in this analysis consists of the following criteria:
* The property class groups consist of the following `reporting_group`: `"Single-Family", "Multi-Family", "Condominium"`. We filter to where `major_class_type` == `"Residential"` and `regression_class` == `TRUE` and `reporting_group` != `"Bed & Breakfast"`. For details about property classes see these dictionaries [class_dict.csv](https://raw.githubusercontent.com/ccao-data/ccao/master/data-raw/class_dict.csv), [classcode.pdf](Source: https://prodassets.cookcountyassessor.com/s3fs-public/form_documents/classcode.pdf), or the R function [ccao::class_dict](https://ccao-data.github.io/ccao/reference/class_dict.html).
* Removed outliers that did not pass the IAAO IQR rule, were less than three standard deviations from mean, and had both an assess value (mailed) and sale price over 100. 
* The comparison years consist of `"2018 vs. 2021"` for the city, `"2017 vs. 2020"` for the south triad, and `"2016 vs. 2022"` for the north triad. We used 2022 instead of 2019 because 2019 was the first year of the Kaegi administration and they had not yet full instituted changes to their automated valuation models, thus dropping 2019 from the analysis provides a break year to accommodate the time it took to implement new systems.
* For inflation adjustments we used the [FHFA HPI Expanded-Data Index](https://www.fhfa.gov/DataTools/Downloads/Pages/House-Price-Index-Datasets.aspx#qexe) (Estimated using Enterprise, FHA, and Real Property County Recorder Data Licensed from DataQuick for sales below the annual loan limit ceiling) 
