import { getOrders } from './api/orders/orders-api';
import { getProducts } from './api/catalog/catalog-api';

console.log(getOrders().length, getProducts('').length);
