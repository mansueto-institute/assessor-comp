## Comparative analysis of Assessor's in Chicago

Box link with graphics and source data: https://uchicago.box.com/s/3ak5gc52xn4fcz857ctetigg9rffwffv

### Data sources:
* [Parcel sales data source](https://datacatalog.cookcountyil.gov/Property-Taxation/Assessor-Parcel-Sales/wvhk-k5uv/about_data)
* [Property tax bills data source](https://github.com/ccao-data/ptaxsim#ptaxsim)
* [BoR appeals data source](https://datacatalog.cookcountyil.gov/Property-Taxation/Board-of-Review-Appeal-Decision-History/7pny-nedm/about_data)

### The data universe in this analysis consists of the following criteria:

* **Property class definitions:** The property class groups consist of the following reporting groups: "Single-Family", "Multi-Family", "Condominium". We filter to where major_class_type == "Residential" and regression_class == TRUE and reporting_group != "Bed & Breakfast". For details about property classes see these dictionaries class_dict.csv, [classcode.pdf](Source: https://prodassets.cookcountyassessor.com/s3fs-public/form_documents/classcode.pdf), or the R function `ccao::class_dict`. These are the definitions of property classes used in the analysis:
  * Single Family − 202, 203, 204, 205, 206, 207, 208, 209, 210, 234, 278, 295. 
  * Multi Family − 212, 213. 
  * Condominium − 299, 399.
  * Commercial – 500, 501, 516, 517, 522, 523, 526, 527, 528, 529, 530, 531, 532, 533, 535, 590, 591, 592, 597, 599. 
* **Removal of outliers:** We removed observations that did not pass the IAAO IQR rule, with sales greater than three standard deviations from mean, or had assessed value (mailed) or sale price below 100 dollars. In case of multiple sale transactions, we limit to the most recent sale for a given property within each year.
* **Comparison years:** The comparison years consist of "2018 vs. 2021" for the city, "2017 vs. 2020" for the south triad, and "2016 vs. 2022" for the north triad. We used 2022 instead of 2019 because 2019 was the first year of the Kaegi administration and they had not yet fully instituted changes to their automated valuation models, thus dropping 2019 from the analysis provides a break year to accommodate the time it took to implement new systems.
* **Inflation adjustment:** Sale prices are inflation adjusted to 2023 dollars using FHFA HPI Expanded-Data Index (Estimated using Enterprise, FHA, and Real Property County Recorder Data Licensed from DataQuick for sales below the annual loan limit ceiling)
